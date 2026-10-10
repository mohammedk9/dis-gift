/* تشخيص: لماذا تظهر قائمة الحساب "غير مسجل / بدون منشأة"؟ — قراءة فقط */
const fs = require('fs');
const path = require('path');
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
const DB = env.DIRECT_URL || env.DATABASE_URL;

(async () => {
  const sql = new Client({ connectionString: DB, ssl: { rejectUnauthorized: false } });
  await sql.connect();
  const show = async (label, q) => {
    console.log('\n===== ' + label + ' =====');
    try { console.log(JSON.stringify((await sql.query(q)).rows, null, 2)); }
    catch (e) { console.log('ERROR: ' + e.message); }
  };

  await show('profiles', `select id, role, name, phone, created_at from public.profiles order by created_at`);

  await show('auth.users (email + id only)', `select id, email, created_at,
      email_confirmed_at is not null as confirmed from auth.users order by created_at`);

  await show('join: user -> profile -> staff -> restaurant', `
    select u.email, p.role as profile_role, rs.role as staff_role,
           r.name as restaurant, r.status as restaurant_status, u.id as user_id
      from auth.users u
      left join public.profiles p on p.id = u.id
      left join public.restaurant_staff rs on rs.user_id = u.id
      left join public.restaurants r on r.id = rs.restaurant_id
     order by u.created_at`);

  await show('profiles RLS policies', `select pol.polname, pol.polcmd,
      pg_get_expr(pol.polqual, pol.polrelid) as using_expr
    from pg_policy pol where pol.polrelid = 'public.profiles'::regclass`);

  await show('anon privileges on profiles/restaurants/restaurant_staff', `
    select t as tbl, priv as privilege, has_table_privilege('anon', t, priv) as anon_has
      from (values ('public.profiles'),('public.restaurants'),
                   ('public.restaurant_staff'),('public.menu_items')) v(t),
           (values ('SELECT')) p(priv)`);

  await sql.end();
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
