/* تحقق حيّ: هل يرى الزائر المجهول أي عرض؟ (قراءة فقط، بلا أي كتابة) */
const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');
const { Client } = require('pg');

function loadEnv() {
  const out = {};
  for (const line of fs.readFileSync(path.join(__dirname, '..', '.env'), 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}
const env = { ...loadEnv(), ...process.env };
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const DB = env.DIRECT_URL || env.DATABASE_URL;

(async () => {
  const sql = new Client({ connectionString: DB, ssl: { rejectUnauthorized: false } });
  await sql.connect();
  const q = async (label, s) => {
    console.log('\n===== ' + label + ' =====');
    try { console.log(JSON.stringify((await sql.query(s)).rows, null, 1)); }
    catch (e) { console.log('ERROR: ' + e.message); }
  };

  await q('admin_users', `select user_id, role from public.admin_users`);
  await q('offers by restaurant status', `
    select r.name, r.status, count(o.id) as offers, count(o.id) filter (where o.is_enabled) as enabled
      from public.restaurants r left join public.offers o on o.restaurant_id = r.id
     group by r.name, r.status`);
  await q('restaurants.status is what blocks the gift', `
    select count(*) filter (where status = 'active')  as active_restaurants,
           count(*) filter (where status = 'pending') as pending_restaurants
      from public.restaurants`);

  const anon = createClient(URL, ANON, { auth: { persistSession: false } });

  console.log('\n===== ANON: select restaurants =====');
  console.log(JSON.stringify((await anon.from('restaurants').select('id,name,status')).data, null, 1));

  console.log('\n===== ANON: select offers =====');
  console.log(JSON.stringify(await anon.from('offers').select('*'), null, 1));

  console.log('\n===== ANON: rpc open_daily_gift =====');
  const g = await anon.rpc('open_daily_gift', {
    p_device: '00000000-0000-0000-0000-000000000000', p_area: null });
  console.log(JSON.stringify(g, null, 1));

  console.log('\n===== ANON: rpc active_areas (a working public RPC for comparison) =====');
  console.log(JSON.stringify((await anon.rpc('active_areas')).data, null, 1));

  await sql.end();
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
