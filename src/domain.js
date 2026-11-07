export const money=n=>new Intl.NumberFormat('es-CL',{style:'currency',currency:'CLP',maximumFractionDigits:0}).format(Number(n)||0);
export function today(now=new Date()){const p=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Santiago',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);const v=t=>p.find(x=>x.type===t).value;return `${v('year')}-${v('month')}-${v('day')}`}
export const month=d=>d.slice(0,7);
export const monthLabel=m=>new Intl.DateTimeFormat('es-CL',{month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(m+'-01T12:00:00Z'));
export const dateLabel=d=>new Intl.DateTimeFormat('es-CL',{day:'numeric',month:'short',year:'numeric',timeZone:'UTC'}).format(new Date(d+'T12:00:00Z'));
export const sum=xs=>xs.reduce((n,x)=>n+Number(x.amount),0);
export const normalizeLabel=s=>String(s??'').trim().replace(/\s+/g,' ').toLocaleLowerCase('es-CL');
export function allocationError(total,lines){if(!Number.isSafeInteger(Number(total))||Number(total)<1||Number(total)>999999999999)return 'Ingresá el total que pagaste.';if(!lines.length||lines.some(l=>!Number.isSafeInteger(Number(l.amount))||Number(l.amount)<1))return 'Cada línea debe tener un monto entero mayor a cero.';const assigned=sum(lines),difference=Number(total)-assigned;return difference===0?'':difference>0?`Falta asignar ${money(difference)}.`:`Las líneas exceden el total en ${money(-difference)}.`}
export function group(xs,key){return xs.reduce((out,x)=>{const k=key(x);(out[k]??=[]).push(x);return out},{})}
export function selectedExpenses(expenses,ids){const rows=expenses.filter(x=>ids.has(x.id)&&!x.reimbursement_id);if(new Set(rows.map(x=>x.responsible_id)).size>1)throw Error('Seleccioná gastos de un solo responsable.');return rows}
export function csv(rows){return '\uFEFF'+rows.map(row=>row.map(v=>{let s=String(v??'');if(/^[\s]*[=+\-@]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"'}).join(';')).join('\r\n')}
