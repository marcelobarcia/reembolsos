begin;
insert into auth.users(id,email) values('33333333-3333-4333-8333-333333333333','split-a@example.invalid'),('44444444-4444-4444-8444-444444444444','split-b@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
do $$declare a uuid;b uuid;begin
 a:=public.ensure_responsible('Granero Fino');b:=public.ensure_responsible('  GRANERO   fino ');
 if a<>b or (select count(*) from public.responsibles)<>1 then raise exception 'FALLO: catálogo de personas';end if;
end $$;
select public.mutate('save_payment','{"id":"55555555-5555-4555-8555-555555555555","amount":40122,"merchant":"Comercio QA","expense_date":"2026-10-31","lines":[{"id":"66666666-6666-4666-8666-666666666666","amount":24343,"description":"Parte de otra persona","responsible_name":"Otra persona"},{"id":"77777777-7777-4777-8777-777777777777","amount":15779,"description":"Parte del negocio","responsible_name":" Granero  FINO "}]}');
-- Repetir un guardado no duplica el pago ni sus líneas.
select public.mutate('save_payment','{"id":"55555555-5555-4555-8555-555555555555","amount":40122,"merchant":"  COMERCIO   qa ","expense_date":"2026-10-31","lines":[{"id":"66666666-6666-4666-8666-666666666666","amount":24343,"description":"Parte de otra persona","responsible_name":"Otra persona"},{"id":"77777777-7777-4777-8777-777777777777","amount":15779,"description":"Parte del negocio","responsible_name":"Granero Fino"}]}');
do $$begin
 if (select count(*) from public.purchases)<>1 or (select count(*) from public.expenses)<>2 or (select sum(amount) from public.expenses)<>40122 then raise exception 'FALLO: distribución o idempotencia';end if;
 if (select count(*) from public.merchants)<>1 or (select count(*) from public.responsibles)<>2 then raise exception 'FALLO: duplicados en catálogos';end if;
 if (select merchant from public.purchases limit 1)<>'Comercio QA' then raise exception 'FALLO: comercio canónico';end if;
 begin
  perform public.mutate('save_payment','{"id":"55555555-5555-4555-8555-555555555555","amount":40123,"merchant":"No debe guardarse","expense_date":"2026-11-07","lines":[{"id":"66666666-6666-4666-8666-666666666666","amount":40122,"description":"Mal total","responsible_name":"Otra persona"}]}');
  raise exception 'FALLO: total incoherente';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 -- Fallo tardío: no debe dejar pago, línea ni comercio parcialmente guardados.
 begin
  perform public.mutate('save_payment','{"id":"55555555-5555-4555-8555-555555555555","amount":40122,"merchant":"No debe guardarse","expense_date":"2026-11-07","lines":[{"id":"66666666-6666-4666-8666-666666666666","amount":40122,"description":"Sin persona","responsible_name":" "}]}');
  raise exception 'FALLO: persona vacía';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 if (select count(*) from public.expenses)<>2 or (select count(*) from public.merchants)<>1 or (select amount from public.purchases limit 1)<>40122 then raise exception 'FALLO: guardado parcial';end if;
end $$;
do $$declare rid uuid;begin
 select responsible_id into rid from public.expenses where id='66666666-6666-4666-8666-666666666666';
 perform public.mutate('record_reimbursement',jsonb_build_object('id','88888888-8888-4888-8888-888888888888','responsible_id',rid,'transfer_date','2026-11-07','expense_ids',jsonb_build_array('66666666-6666-4666-8666-666666666666')));
 if (select sum(amount) from public.expenses where reimbursement_id is null)<>15779 then raise exception 'FALLO: reembolso parcial';end if;
 if (select amount from public.purchases limit 1)<>40122 or (select amount from public.reimbursements limit 1)<>24343 then raise exception 'FALLO: pago original';end if;
 begin
  perform public.mutate('delete_payment','{"id":"55555555-5555-4555-8555-555555555555"}');
  raise exception 'FALLO: borrar pago parcialmente reembolsado';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
 begin
  perform public.mutate('save_expense',jsonb_build_object('id','77777777-7777-4777-8777-777777777777','amount',1,'merchant','Alterado','description','Alterado','responsible_id',rid,'expense_date','2026-11-07'));
  raise exception 'FALLO: cliente antiguo alteró pago dividido';
 exception when raise_exception then if sqlerrm like 'FALLO:%' then raise;end if;end;
end $$;
select set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444444',true);
do $$begin
 if (select count(*) from public.purchases)<>0 or (select count(*) from public.merchants)<>0 or (select count(*) from public.expenses)<>0 or (select count(*) from public.responsibles)<>0 then raise exception 'FALLO: RLS';end if;
 begin
  perform public.mutate('delete_payment','{"id":"55555555-5555-4555-8555-555555555555"}');raise exception 'FALLO: borrado ajeno';
 exception when insufficient_privilege then null;end;
 begin
  perform public.mutate('save_payment','{"id":"55555555-5555-4555-8555-555555555555","amount":1,"merchant":"Ajeno","expense_date":"2026-11-07","lines":[{"id":"99999999-9999-4999-8999-999999999999","amount":1,"description":"Ajeno","responsible_name":"Persona"}]}');raise exception 'FALLO: edición ajena';
 exception when insufficient_privilege then null;end;
 begin
  insert into public.purchases(id,owner_id,merchant,amount,expense_date) values(gen_random_uuid(),auth.uid(),'Directo',1,current_date);raise exception 'FALLO: escritura directa';
 exception when insufficient_privilege then null;end;
end $$;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
select public.mutate('undo_reimbursement','{"id":"88888888-8888-4888-8888-888888888888"}');
select public.mutate('delete_payment','{"id":"55555555-5555-4555-8555-555555555555"}');
do $$begin
 if exists(select 1 from public.expenses) or exists(select 1 from public.purchases) then raise exception 'FALLO: borrado del pago completo';end if;
 if (select count(*) from public.merchants)<>1 or (select count(*) from public.responsibles)<>2 then raise exception 'FALLO: no conservó catálogos';end if;
end $$;
select 'PASS: reparto 40.122=24.343+15.779, reembolso parcial, total original, catálogos, rollback, RLS y compatibilidad' result;
rollback;
