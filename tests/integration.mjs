// QA contra un proyecto autorizado. Credenciales efímeras por stdin, nunca Git.
import {createClient} from '@supabase/supabase-js';
import assert from 'node:assert/strict';
import {SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY} from '../src/config.js';
let input='';for await(const chunk of process.stdin)input+=chunk;const qa=JSON.parse(input);
const client=()=>createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
const a=client(),b=client();
function ok(r){if(r.error)throw r.error;return r.data}
ok(await a.auth.signInWithPassword({email:qa.emailA,password:qa.password}));
ok(await b.auth.signInWithPassword({email:qa.emailB,password:qa.password}));
const rid=crypto.randomUUID(),ridB=crypto.randomUUID(),expense=crypto.randomUUID(),payment=crypto.randomUUID();
ok(await a.from('responsibles').insert({id:rid,name:'QA concurrencia'}));
ok(await b.from('responsibles').insert({id:ridB,name:'QA otro usuario'}));
const payload={id:expense,amount:12345,merchant:'QA concurrente',description:'Prueba efímera',responsible_id:rid,expense_date:'2026-10-31'};
ok(await a.rpc('mutate',{action:'save_expense',p:payload}));
assert.equal(ok(await b.from('expenses').select('*').eq('id',expense)).length,0);
const intrusion=await b.rpc('mutate',{action:'save_expense',p:{...payload,responsible_id:ridB}});assert(intrusion.error);
const p={id:payment,responsible_id:rid,transfer_date:'2026-11-07',expense_ids:[expense]};
// Dos peticiones concurrentes con IDs distintos: exactamente una debe ganar.
const race=await Promise.all([a.rpc('mutate',{action:'record_reimbursement',p}),a.rpc('mutate',{action:'record_reimbursement',p:{...p,id:crypto.randomUUID()}})]);
assert.equal(race.filter(r=>!r.error).length,1);assert.equal(race.filter(r=>r.error).length,1);
let rows=ok(await a.from('expenses').select('*').eq('id',expense));const winning=rows[0].reimbursement_id;assert(winning);
// El mismo request simultáneo se confirma sin duplicar.
const retries=await Promise.all([a.rpc('mutate',{action:'record_reimbursement',p:{...p,id:winning}}),a.rpc('mutate',{action:'record_reimbursement',p:{...p,id:winning}})]);retries.forEach(ok);
const history=ok(await a.from('reimbursements').select('*').eq('id',winning));assert.equal(history.length,1);assert.equal(history[0].amount,12345);
assert((await a.rpc('mutate',{action:'save_expense',p:{...payload,amount:1}})).error);
assert((await b.rpc('mutate',{action:'undo_reimbursement',p:{id:winning}})).error);
assert((await a.from('expenses').update({amount:1}).eq('id',expense)).error);
// Storage real: carga, lectura autorizada y rechazo entre propietarios.
const path=`${qa.a}/${crypto.randomUUID()}.pdf`;const pdf=new Blob(['%PDF-1.4\n% QA temporal\n'],{type:'application/pdf'});
ok(await a.storage.from('attachments').upload(path,pdf,{contentType:'application/pdf'}));
ok(await a.storage.from('attachments').download(path));
assert((await b.storage.from('attachments').download(path)).error);
assert((await b.storage.from('attachments').upload(`${qa.a}/${crypto.randomUUID()}.pdf`,pdf)).error);
assert((await client().storage.from('attachments').download(path)).error);
ok(await a.storage.from('attachments').remove([path]));
ok(await a.rpc('mutate',{action:'undo_reimbursement',p:{id:winning}}));
rows=ok(await a.from('expenses').select('*').eq('id',expense));assert.equal(rows[0].reimbursement_id,null);
ok(await a.rpc('mutate',{action:'save_expense',p:{...payload,amount:20000}}));
ok(await a.rpc('mutate',{action:'delete_expense',p:{id:expense}}));
assert.equal(ok(await a.from('expenses').select('*').eq('id',expense)).length,0);
await a.auth.signOut();await b.auth.signOut();
console.log('PASS: API real, RLS, escritura bloqueada, carrera concurrente, reintentos, Storage privado, deshacer y edición.');
