/* تحقق: هل يستطيع الزائر المجهول قراءة العروض النشطة الآن؟ */
const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

function loadEnv() {
  const out = {};
  for (const line of fs.readFileSync(path.join(__dirname, '..', '.env'), 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}
const env = { ...loadEnv(), ...process.env };
const anon = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  { auth: { persistSession: false } });

(async () => {
  console.log('\n===== ANON rpc public_offers() — this is what the storefront will call =====');
  const r = await anon.rpc('public_offers', { p_area: null });
  console.log('error:', JSON.stringify(r.error));
  console.log('data :', JSON.stringify(r.data, null, 1));
  console.log('\n===== ANON rpc public_offers(p_area=2) =====');
  const r2 = await anon.rpc('public_offers', { p_area: 2 });
  console.log('data :', JSON.stringify(r2.data, null, 1));
  console.log('\n===== ANON rpc public_offers(p_area=99) — a different area should be empty =====');
  const r3 = await anon.rpc('public_offers', { p_area: 99 });
  console.log('data :', JSON.stringify(r3.data, null, 1));
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
