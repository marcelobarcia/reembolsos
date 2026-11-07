-- v2: un pago original y sus líneas reembolsables. Migración no destructiva.
begin;
alter table public.responsibles add column name_key text generated always as (lower(regexp_replace(btrim(name),'\s+',' ','g'))) stored;
alter table public.expenses alter constraint expenses_reimbursement_id_owner_id_responsible_id_fkey deferrable initially deferred;
create temporary table responsible_merge on commit drop as select id,first_value(id) over(partition by owner_id,name_key order by created_at,id) canonical from public.responsibles;
update public.reimbursements r set responsible_id=m.canonical from responsible_merge m where r.responsible_id=m.id and m.id<>m.canonical;
update public.expenses e set responsible_id=m.canonical from responsible_merge m where e.responsible_id=m.id and m.id<>m.canonical;
delete from public.responsibles r using responsible_merge m where r.id=m.id and m.id<>m.canonical;
create unique index responsibles_owner_name_key on public.responsibles(owner_id,name_key);

create table public.merchants (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 name text not null check(length(trim(name)) between 1 and 200),
 name_key text generated always as (lower(regexp_replace(btrim(name),'\s+',' ','g'))) stored,
 created_at timestamptz not null default now(),
 unique(owner_id,name_key)
);
create table public.purchases (
 id uuid primary key,
 owner_id uuid not null references auth.users(id) on delete cascade,
 merchant text not null check(length(trim(merchant)) between 1 and 200),
 amount bigint not null check(amount between 1 and 999999999999),
 expense_date date not null,
 receipt_path text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(id,owner_id)
);
alter table public.merchants enable row level security;
alter table public.purchases enable row level security;
create policy merchants_own_read on public.merchants for select to authenticated using(owner_id=(select auth.uid()));
create policy purchases_own_read on public.purchases for select to authenticated using(owner_id=(select auth.uid()));
revoke all on public.merchants,public.purchases from anon,authenticated;
grant select on public.merchants,public.purchases to authenticated;
create index purchases_owner_date on public.purchases(owner_id,expense_date desc);
alter table public.expenses add column purchase_id uuid;
alter table public.expenses add column position integer not null default 0 check(position>=0);
insert into public.purchases(id,owner_id,merchant,amount,expense_date,receipt_path,created_at,updated_at) select id,owner_id,merchant,amount,expense_date,receipt_path,created_at,updated_at from public.expenses;
update public.expenses set purchase_id=id;
alter table public.expenses alter column purchase_id set not null;
alter table public.expenses add constraint expenses_purchase_owner_fk foreign key(purchase_id,owner_id) references public.purchases(id,owner_id);
create index expenses_purchase_owner on public.expenses(purchase_id,owner_id);
insert into public.merchants(owner_id,name) select distinct on(owner_id,lower(regexp_replace(btrim(merchant),'\s+',' ','g'))) owner_id,regexp_replace(btrim(merchant),'\s+',' ','g') from public.expenses order by owner_id,lower(regexp_replace(btrim(merchant),'\s+',' ','g')),created_at;

create function private.ensure_responsible(label text) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); result uuid; clean text:=regexp_replace(btrim(label),'\s+',' ','g');
begin
 if u is null then raise exception 'Iniciá sesión.' using errcode='42501';end if;
 if clean is null or length(clean) not between 1 and 100 then raise exception 'Ingresá un responsable de hasta 100 caracteres.';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u::text,0));
 insert into public.responsibles(owner_id,name) values(u,clean) on conflict do nothing;
 select id into result from public.responsibles where owner_id=u and name_key=lower(clean);
 return result;
end $$;
revoke all on function private.ensure_responsible(text) from public,anon,authenticated;
create function public.ensure_responsible(label text) returns uuid language sql security invoker set search_path='' as $$select private.ensure_responsible(label)$$;
revoke all on function public.ensure_responsible(text) from public,anon;
grant execute on function private.ensure_responsible(text),public.ensure_responsible(text) to authenticated;

-- Conserva el motor probado de registro/anulación de reembolsos.
alter function private.mutate(text,jsonb) rename to mutate_v1;
revoke all on function private.mutate_v1(text,jsonb) from public,anon,authenticated;
create function private.mutate(action text,p jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare
 u uuid:=auth.uid(); pid uuid:=(p->>'id')::uuid; purchase public.purchases;
 line jsonb; lid uuid; rid uuid; ids uuid[]:='{}'; total bigint:=0;
 expected bigint; clean text; canonical text; path text; pos integer:=0; e public.expenses;
begin
 if u is null then raise exception 'Iniciá sesión para continuar.' using errcode='42501';end if;
 if pid is null then raise exception 'Falta el identificador.';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u::text,0));
 if action='save_payment' then
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 100 then raise exception 'Agregá entre 1 y 100 líneas al pago.';end if;
  if coalesce(p->>'amount','') !~ '^[0-9]+$' then raise exception 'Ingresá un monto total entero en pesos.';end if;
  expected:=(p->>'amount')::bigint;
  if expected not between 1 and 999999999999 then raise exception 'Monto total fuera de rango.';end if;
  select * into purchase from public.purchases where id=pid for update;
  if found and purchase.owner_id<>u then raise exception 'Pago no disponible.' using errcode='42501';end if;
  if exists(select 1 from public.expenses where purchase_id=pid and reimbursement_id is not null) then raise exception 'Deshacé primero los reembolsos de este pago para poder editarlo.';end if;
  clean:=regexp_replace(btrim(p->>'merchant'),'\s+',' ','g');
  if clean is null or length(clean) not between 1 and 200 then raise exception 'Ingresá el comercio o destinatario.';end if;
  path:=nullif(p->>'receipt_path','');
  if path is not null and (split_part(path,'/',1)<>u::text or not exists(select 1 from storage.objects where bucket_id='attachments' and name=path)) then raise exception 'Boleta inválida.';end if;
  -- Validar toda la distribución antes de crear catálogos o cambiar registros.
  for line in select value from jsonb_array_elements(p->'lines') loop
   lid:=(line->>'id')::uuid;
   if lid is null or lid=any(ids) then raise exception 'Las líneas deben tener identificadores distintos.';end if;
   ids:=array_append(ids,lid);
   if coalesce(line->>'amount','') !~ '^[0-9]+$' or (line->>'amount')::bigint not between 1 and 999999999999 then raise exception 'Cada línea debe tener un monto entero mayor a cero.';end if;
   total:=total+(line->>'amount')::bigint;
   if coalesce(length(trim(line->>'description')),0) not between 1 and 2000 then raise exception 'Completá la descripción de cada línea.';end if;
   if exists(select 1 from public.expenses where id=lid and (owner_id<>u or purchase_id<>pid)) then raise exception 'Línea no disponible.' using errcode='42501';end if;
  end loop;
  if total<>expected then raise exception 'Las líneas suman %, pero el total pagado es %. Ajustá el desglose.',total,expected;end if;
  insert into public.merchants(owner_id,name) values(u,clean) on conflict do nothing;
  select name into canonical from public.merchants where owner_id=u and name_key=lower(clean);
  insert into public.purchases(id,owner_id,merchant,amount,expense_date,receipt_path) values(pid,u,canonical,expected,(p->>'expense_date')::date,path)
   on conflict(id) do update set merchant=excluded.merchant,amount=excluded.amount,expense_date=excluded.expense_date,receipt_path=excluded.receipt_path,updated_at=now();
  delete from public.expenses where purchase_id=pid and owner_id=u and not(id=any(ids));
  for line in select value from jsonb_array_elements(p->'lines') loop
   if nullif(line->>'responsible_id','') is not null then
    rid:=(line->>'responsible_id')::uuid;
    if not exists(select 1 from public.responsibles where id=rid and owner_id=u) then raise exception 'Responsable inválido.' using errcode='42501';end if;
   else rid:=private.ensure_responsible(line->>'responsible_name');end if;
   insert into public.expenses(id,owner_id,purchase_id,position,responsible_id,amount,merchant,description,expense_date,receipt_path) values((line->>'id')::uuid,u,pid,pos,rid,(line->>'amount')::bigint,canonical,trim(line->>'description'),(p->>'expense_date')::date,path)
    on conflict(id) do update set position=excluded.position,responsible_id=excluded.responsible_id,amount=excluded.amount,merchant=excluded.merchant,description=excluded.description,expense_date=excluded.expense_date,receipt_path=excluded.receipt_path,updated_at=now();
   pos:=pos+1;
  end loop;
  return pid;
 elsif action='delete_payment' then
  select * into purchase from public.purchases where id=pid and owner_id=u for update;
  if not found then raise exception 'Pago no disponible.' using errcode='42501';end if;
  if exists(select 1 from public.expenses where purchase_id=pid and reimbursement_id is not null) then raise exception 'Deshacé primero los reembolsos de este pago para eliminarlo.';end if;
  delete from public.expenses where purchase_id=pid and owner_id=u;
  delete from public.purchases where id=pid and owner_id=u;
  return pid;
 elsif action in ('save_expense','delete_expense') then
  -- Compatibilidad para pestañas anteriores: nunca fragmentar un pago con varias líneas.
  select * into e from public.expenses where id=pid;
  if found then
   if e.owner_id<>u then raise exception 'Gasto no disponible.' using errcode='42501';end if;
   if (select count(*) from public.expenses where purchase_id=e.purchase_id)>1 then raise exception 'Este gasto es parte de un pago dividido. Actualizá la aplicación y editá el pago completo.';end if;
  end if;
  if action='delete_expense' then
   if e.id is null then raise exception 'Gasto no disponible.';end if;
   return private.mutate('delete_payment',jsonb_build_object('id',e.purchase_id));
  end if;
  return private.mutate('save_payment',jsonb_build_object('id',coalesce(e.purchase_id,pid),'amount',p->'amount','merchant',p->'merchant','expense_date',p->'expense_date','receipt_path',p->'receipt_path','lines',jsonb_build_array(jsonb_build_object('id',pid,'amount',p->'amount','description',p->'description','responsible_id',p->'responsible_id'))));
 elsif action in ('record_reimbursement','undo_reimbursement') then
  return private.mutate_v1(action,p);
 end if;
 raise exception 'Acción inválida.';
end $$;
revoke all on function private.mutate(text,jsonb) from public,anon;
grant execute on function private.mutate(text,jsonb) to authenticated;
create or replace function public.mutate(action text,p jsonb) returns uuid language sql security invoker set search_path='' as $$select private.mutate(action,p)$$;
-- No borrar la boleta del pago original aunque se cambien sus líneas.
drop policy attachments_delete_orphan on storage.objects;
create policy attachments_delete_orphan on storage.objects for delete to authenticated using(bucket_id='attachments' and (storage.foldername(name))[1]=(select auth.uid())::text and not exists(select 1 from public.expenses e where e.receipt_path=name) and not exists(select 1 from public.purchases p where p.receipt_path=name) and not exists(select 1 from public.reimbursements r where r.proof_path=name));
commit;
