-- Ejecutar como postgres. Todo se revierte, incluidos usuarios de prueba.
begin;
insert into auth.users(id,email) values('11111111-1111-4111-8111-111111111111','qa-a@example.invalid'),('22222222-2222-4222-8222-222222222222','qa-b@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
insert into public.responsibles(id,name) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Responsable QA'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Otro QA');
select public.mutate('save_expense','{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","amount":1500,"merchant":"Prueba","description":"Solo transacción de prueba","expense_date":"2026-10-31"}');
select public.mutate('save_expense','{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","responsible_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","amount":2500,"merchant":"Prueba 2","description":"Solo transacción de prueba","expense_date":"2026-11-01"}');
do $$begin
 begin
  perform public.mutate('record_reimbursement','{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","transfer_date":"2026-11-07","expense_ids":["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","dddddddd-dddd-4ddd-8ddd-dddddddddddd"]}');
  raise exception 'FALLO: permitió mezcla';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 if (select count(*) from public.reimbursements)<>0 then raise exception 'FALLO: operación parcial';end if;
 if (select count(*) from public.expenses where reimbursement_id is null)<>2 then raise exception 'FALLO: operación parcial gastos';end if;
end $$;
select public.mutate('record_reimbursement','{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","transfer_date":"2026-11-07","expense_ids":["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]}');
-- El mismo request devuelve el mismo ID (reintento seguro).
select public.mutate('record_reimbursement','{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","transfer_date":"2026-11-07","expense_ids":["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]}');
do $$begin
 if (select count(*) from public.reimbursements)<>1 then raise exception 'FALLO: duplicación';end if;
 if (select amount from public.reimbursements limit 1)<>1500 then raise exception 'FALLO: total';end if;
 begin
  perform public.mutate('record_reimbursement','{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","transfer_date":"2026-11-07","expense_ids":["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"]}');
  raise exception 'FALLO: doble reembolso';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 begin
  perform public.mutate('save_expense','{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","amount":999,"merchant":"Cambio","description":"Cambio","expense_date":"2026-11-07"}');
  raise exception 'FALLO: edición reembolsado';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 begin
  perform public.mutate('delete_expense','{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}');
  raise exception 'FALLO: borrado reembolsado';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 begin
  update public.expenses set reimbursement_id=null;
  raise exception 'FALLO: escritura directa';
 exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$begin
 if (select count(*) from public.expenses)<>0 or (select count(*) from public.responsibles)<>0 or (select count(*) from public.reimbursements)<>0 then raise exception 'FALLO: aislamiento RLS';end if;
 begin
  perform public.mutate('undo_reimbursement','{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff"}');
  raise exception 'FALLO: deshacer ajeno';
 exception when insufficient_privilege then null;end;
 begin
  perform public.mutate('save_expense','{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","responsible_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","amount":1,"merchant":"Ajeno","description":"Ajeno","expense_date":"2026-11-07"}');
  raise exception 'FALLO: editar ajeno';
 exception when insufficient_privilege then null; when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 begin
  insert into public.responsibles(owner_id,name) values('11111111-1111-4111-8111-111111111111','Ataque');
  raise exception 'FALLO: propietario falso';
 exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select public.mutate('undo_reimbursement','{"id":"ffffffff-ffff-4fff-8fff-ffffffffffff"}');
do $$begin
 if (select count(*) from public.expenses where reimbursement_id is null)<>2 then raise exception 'FALLO: deshacer';end if;
 if (select count(*) from public.reimbursements where voided_at is not null)<>1 then raise exception 'FALLO: trazabilidad';end if;
end $$;
select public.mutate('delete_expense','{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}');
select 'PASS: aislamiento, atomicidad, idempotencia, duplicados, edición, borrado y deshacer' as result;
rollback;
