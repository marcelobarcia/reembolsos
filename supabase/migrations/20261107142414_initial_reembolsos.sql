-- Reembolsos v1. Aplicar una vez en un proyecto vacío.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.responsibles (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 name text not null check(length(trim(name)) between 1 and 100),
 created_at timestamptz not null default now(),
 unique(id,owner_id), unique(owner_id,name)
);
create table public.reimbursements (
 id uuid primary key,
 owner_id uuid not null references auth.users(id) on delete cascade,
 responsible_id uuid not null,
 transfer_date date not null,
 amount bigint not null check(amount>0 and amount<=9007199254740991),
 proof_path text,
 expense_ids uuid[] not null check(cardinality(expense_ids)>0),
 created_at timestamptz not null default now(),
 voided_at timestamptz,
 unique(id,owner_id,responsible_id),
 foreign key(responsible_id,owner_id) references public.responsibles(id,owner_id)
);
create table public.expenses (
 id uuid primary key,
 owner_id uuid not null references auth.users(id) on delete cascade,
 responsible_id uuid not null,
 amount bigint not null check(amount between 1 and 999999999999),
 merchant text not null check(length(trim(merchant)) between 1 and 200),
 description text not null check(length(trim(description)) between 1 and 2000),
 expense_date date not null,
 receipt_path text,
 reimbursement_id uuid,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 foreign key(responsible_id,owner_id) references public.responsibles(id,owner_id),
 foreign key(reimbursement_id,owner_id,responsible_id) references public.reimbursements(id,owner_id,responsible_id)
);
create index expenses_owner_date on public.expenses(owner_id,expense_date desc);
create index expenses_responsible on public.expenses(responsible_id,owner_id);
create index expenses_payment on public.expenses(reimbursement_id,owner_id,responsible_id);
create index reimbursements_owner_date on public.reimbursements(owner_id,transfer_date desc);
create index reimbursements_responsible on public.reimbursements(responsible_id,owner_id);
alter table public.responsibles enable row level security;
alter table public.expenses enable row level security;
alter table public.reimbursements enable row level security;
create policy own_responsibles_read on public.responsibles for select to authenticated using(owner_id=(select auth.uid()));
create policy own_responsibles_insert on public.responsibles for insert to authenticated with check(owner_id=(select auth.uid()));
create policy own_expenses_read on public.expenses for select to authenticated using(owner_id=(select auth.uid()));
create policy own_reimbursements_read on public.reimbursements for select to authenticated using(owner_id=(select auth.uid()));
revoke all on public.responsibles,public.expenses,public.reimbursements from anon,authenticated;
grant select on public.responsibles,public.expenses,public.reimbursements to authenticated;
grant insert on public.responsibles to authenticated;

-- Todas las mutaciones financieras pasan por este límite atómico.
-- Definer es necesario: los clientes no tienen escritura directa a tablas.
-- El esquema privado no está expuesto por PostgREST. UID siempre explícito.
create function private.mutate(action text,p jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 u uuid:=auth.uid(); eid uuid; rid uuid; ids uuid[]; actual_ids uuid[];
 n integer; total bigint; existing public.reimbursements; e public.expenses;
 path text; payment_date date;
begin
 if u is null then raise exception 'Iniciá sesión para continuar.' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u::text,0));
 eid:=(p->>'id')::uuid;
 if eid is null then raise exception 'Falta el identificador.'; end if;
 if action='save_expense' then
  rid:=(p->>'responsible_id')::uuid;path:=nullif(p->>'receipt_path','');
  if not exists(select 1 from public.responsibles where id=rid and owner_id=u) then raise exception 'Responsable inválido.'; end if;
  if path is not null and (split_part(path,'/',1)<>u::text or not exists(select 1 from storage.objects where bucket_id='attachments' and name=path)) then raise exception 'Boleta inválida.'; end if;
  select * into e from public.expenses where id=eid for update;
  if found then
   if e.owner_id<>u then raise exception 'Gasto no disponible.' using errcode='42501';end if;
   if e.reimbursement_id is not null then raise exception 'Deshacé el reembolso antes de editar el gasto.';end if;
   update public.expenses set responsible_id=rid,amount=(p->>'amount')::bigint,merchant=trim(p->>'merchant'),description=trim(p->>'description'),expense_date=(p->>'expense_date')::date,receipt_path=path,updated_at=now() where id=eid and owner_id=u;
  else
   insert into public.expenses(id,owner_id,responsible_id,amount,merchant,description,expense_date,receipt_path) values(eid,u,rid,(p->>'amount')::bigint,trim(p->>'merchant'),trim(p->>'description'),(p->>'expense_date')::date,path);
  end if;
 elsif action='delete_expense' then
  delete from public.expenses where id=eid and owner_id=u and reimbursement_id is null;
  if not found then raise exception 'El gasto ya no está pendiente o no está disponible.';end if;
 elsif action='record_reimbursement' then
  rid:=(p->>'responsible_id')::uuid;path:=nullif(p->>'proof_path','');payment_date:=(p->>'transfer_date')::date;
  select array_agg(distinct value::uuid order by value::uuid) into ids from jsonb_array_elements_text(p->'expense_ids');
  if ids is null or cardinality(ids)=0 or cardinality(ids)>10000 then raise exception 'Seleccioná entre 1 y 10.000 gastos.';end if;
  select * into existing from public.reimbursements where id=eid;
  if found then
   if existing.owner_id=u and existing.responsible_id=rid and existing.expense_ids=ids and existing.transfer_date=payment_date and existing.proof_path is not distinct from path and existing.voided_at is null then return eid;end if;
   raise exception 'Solicitud ya utilizada. Actualizá los pendientes.';
  end if;
  if path is not null and (split_part(path,'/',1)<>u::text or not exists(select 1 from storage.objects where bucket_id='attachments' and name=path)) then raise exception 'Comprobante inválido.'; end if;
  perform id from public.expenses where id=any(ids) and owner_id=u order by id for update;
  select count(*),sum(amount),array_agg(id order by id) into n,total,actual_ids from public.expenses where id=any(ids) and owner_id=u and responsible_id=rid and reimbursement_id is null;
  if n<>cardinality(ids) then raise exception 'Algún gasto ya fue reembolsado, pertenece a otro responsable o no está disponible. Actualizá la lista.';end if;
  insert into public.reimbursements(id,owner_id,responsible_id,transfer_date,amount,proof_path,expense_ids) values(eid,u,rid,payment_date,total,path,ids);
  update public.expenses set reimbursement_id=eid,updated_at=now() where id=any(ids) and owner_id=u;
 elsif action='undo_reimbursement' then
  select * into existing from public.reimbursements where id=eid and owner_id=u for update;
  if not found then raise exception 'Reembolso no disponible.' using errcode='42501';end if;
  if existing.voided_at is not null then return eid;end if;
  update public.expenses set reimbursement_id=null,updated_at=now() where reimbursement_id=eid and owner_id=u;
  update public.reimbursements set voided_at=now() where id=eid and owner_id=u;
 else raise exception 'Acción inválida.';
 end if;
 return eid;
end $$;
revoke all on function private.mutate(text,jsonb) from public,anon,authenticated;
grant execute on function private.mutate(text,jsonb) to authenticated;
create function public.mutate(action text,p jsonb) returns uuid language sql security invoker set search_path='' as $$select private.mutate(action,p)$$;
revoke all on function public.mutate(text,jsonb) from public,anon;
grant execute on function public.mutate(text,jsonb) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('attachments','attachments',false,15728640,array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf']);
create policy attachments_read on storage.objects for select to authenticated using(bucket_id='attachments' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy attachments_insert on storage.objects for insert to authenticated with check(bucket_id='attachments' and (storage.foldername(name))[1]=(select auth.uid())::text);
-- Sin UPDATE: archivos inmutables. DELETE solo para subidas sin referencias.
create policy attachments_delete_orphan on storage.objects for delete to authenticated using(bucket_id='attachments' and (storage.foldername(name))[1]=(select auth.uid())::text and not exists(select 1 from public.expenses e where e.receipt_path=name) and not exists(select 1 from public.reimbursements r where r.proof_path=name));
