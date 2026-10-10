/* فحص: كل دالة لها جسم كامل (begin/end) ولها grant */
const fs = require('fs');
const files = ['0001_schema', '0002_rls', '0003_functions', '0004_seed',
  '0006_admin_bootstrap', '0007_whatsapp', '0008_delivery', '0009_consents', '0010_loyalty',
  '0012_public_offers']
  .map(n => ({ n, sql: fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8') }));

let bad = 0;
for (const { n, sql } of files) {
  const re = /create or replace function\s+([\w.]+)/g;
  let m;
  while ((m = re.exec(sql))) {
    const name = m[1];
    const start = m.index;
    const next = sql.indexOf('create or replace function', start + 10);
    const seg = sql.slice(start, next === -1 ? sql.length : next);
    const hasCloser = /\$\$;/.test(seg);
    const isPlpgsql = /language plpgsql/.test(seg);
    const hasBegin = /\bbegin\b/.test(seg);
    const hasEnd = /\bend\s+\$\$;/.test(seg);
    const ok = hasCloser && (!isPlpgsql || (hasBegin && hasEnd));
    if (!ok) {
      bad++;
      console.log('BAD  ' + n + '  ' + name +
        '  closer=' + hasCloser + ' begin=' + hasBegin + ' end=' + hasEnd);
    }
  }
}

const all = files.map(f => f.sql).join('\n');
const defined = new Set([...all.matchAll(/create or replace function\s+([\w.]+)/g)].map(x => x[1]));
const granted = new Set([...all.matchAll(/grant execute on function\s+([\w.]+)/g)].map(x => x[1]));
const publicApi = [...defined].filter(f => !/^public\.(touch_updated_at|is_admin|is_staff_of|now_riyadh|today_riyadh|is_open_now|within_active_hours|pick_discount|offer_remaining|gift_payload|handle_new_user|new_gift_code|order_invoice_text|consent_purpose|consent_active|mask_phone|points_hard_cap|guard_points_settings|guard_points_ledger|delivery_fee_for|delivery_fee_cap|guard_delivery_fee)$/.test(f));
const missing = publicApi.filter(f => !granted.has(f));
if (missing.length) { bad++; console.log('MISSING GRANT: ' + missing.join(', ')); }

console.log('\nfunctions defined : ' + defined.size);
console.log('public API fns    : ' + publicApi.length);
console.log('grants            : ' + granted.size);
console.log(bad === 0 ? '>>> ALL FUNCTION BODIES COMPLETE AND GRANTED' : '>>> ' + bad + ' PROBLEM(S)');
process.exit(bad === 0 ? 0 : 1);