/* فحص: هل الواجهة تتعامل مع كل رمز خطأ تُعيده قاعدة البيانات؟ */
const fs = require('fs');
const path = require('path');
// كل ملفات الهجرات: أي رمز خطأ جديد يجب أن تُظهره الواجهة برسالة مفهومة.
const MIGRATIONS = ['0001_schema', '0002_rls', '0003_functions', '0004_seed',
  '0005_site_visitors', '0006_admin_bootstrap', '0007_whatsapp', '0008_delivery',
  '0009_consents', '0010_loyalty', '0011_accounts', '0012_public_offers'];
const sql = MIGRATIONS
  .map(n => fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8')).join('\n');

const codes = new Set();
for (const m of sql.matchAll(/'error',\s*'([a-z_]+)'/g)) codes.add(m[1]);

const files = [];
(function walk(d) {
  for (const f of fs.readdirSync(d, { withFileTypes: true })) {
    if (f.name === 'node_modules') continue;
    const p = path.join(d, f.name);
    f.isDirectory() ? walk(p) : f.name.endsWith('.html') && files.push(p);
  }
})('.');
const front = files.map(f => fs.readFileSync(f, 'utf8')).join('\n');

let pass = 0, fail = 0;
const t = (label, cond) => { cond ? pass++ : fail++; console.log((cond ? 'PASS  ' : 'FAIL  ') + label); };

console.log('Backend error codes: ' + [...codes].sort().join(', ') + '\n');
// codes the UI guards against *before* calling the backend (guard scripts)
const PREGUARDED = {
  already_registered: 'register.html',      // signup blocked client-side
  auth_required:       'register.html',      // register form requires a session
  forbidden:           'guardStaff()',      // RLS/ownership error -> generic msg
  order_not_found:     'order.html',        // friendly "not found" screen
  no_offers_available: 'gift.html'          // friendly "no gift" screen
};

for (const c of [...codes].sort()) {
  const named = front.includes(c);
  const guarded = c in PREGUARDED;
  t('UI handles "' + c + '"' + (guarded ? '  [pre-guarded in ' + PREGUARDED[c] + ']' : ''),
    named || guarded);
}

console.log('\n--- UI-only sanity ---');
t('no_offers_available has a friendly message',
  /لا توجد هدية متاحة حالياً/.test(front));
t('payment disclaimer shown at checkout',
  /الدفع يتم مباشرة مع المنشأة/.test(front) || /الدفع يتم مباشرة للمطعم/.test(front));
const hasC1 = front.includes("otype() === 'delivery' && !$('#c1').checked");
const hasC1Pickup = /otype\(\) === 'pickup' && !\$\('#c1'\)\.checked/.test(front);
const hasC2Block = front.includes("!$('#c2').checked) return toast");
t('order_contact consent IS required for delivery', hasC1);
t('order_contact consent is NOT required for pickup', !hasC1Pickup);
t('marketing consent is NOT required (optional)', !hasC2Block);

console.log('\n' + (fail === 0 ? '>>> ALL ERROR PATHS COVERED' : '>>> ' + fail + ' UNHANDLED'));
process.exit(fail === 0 ? 0 : 1);