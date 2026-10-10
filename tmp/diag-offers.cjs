/* تشخيص حيّ: لماذا لا يظهر العرض على الموقع؟ — قراءة فقط */
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
  const show = async (label, q, params) => {
    console.log('\n===== ' + label + ' =====');
    try {
      const r = await sql.query(q, params || []);
      console.log(JSON.stringify(r.rows, null, 2));
    } catch (e) { console.log('ERROR: ' + e.message); }
  };

  await show('clock', `select now() as utc_now, now() at time zone 'Asia/Riyadh' as riyadh_now,
      public.today_riyadh() as today_riyadh, public.now_riyadh() as now_riyadh_fn`);

  await show('offers rows', `select o.id, o.restaurant_id, o.kind, o.title, o.is_enabled,
      o.active_from, o.active_until, o.active_hours, o.daily_limit, o.redeemed_today, o.redeemed_on,
      (o.active_from is null or o.active_from <= now()) as from_ok,
      (o.active_until is null or o.active_until >= now()) as until_ok,
      public.within_active_hours(o.active_hours) as hours_ok
    from public.offers o`);

  await show('restaurants', `select id, name, status, area_id, city, pickup_enabled, delivery_enabled
    from public.restaurants`);

  await show('restaurant_staff', `select restaurant_id, user_id, role from public.restaurant_staff`);

  await show('offers candidate query (the exact filter open_daily_gift uses)', `
    select of.id, of.title
      from public.offers of
      join public.restaurants r on r.id = of.restaurant_id
     where of.is_enabled
       and r.status = 'active'
       and (of.active_from  is null or of.active_from  <= now())
       and (of.active_until is null or of.active_until >= now())
       and public.within_active_hours(of.active_hours)`);

  await show('RLS policies on offers', `select pol.polname, pol.polcmd, pol.polroles::regrole[] as roles,
      pg_get_expr(pol.polqual, pol.polrelid) as using_expr,
      pg_get_expr(pol.polwithcheck, pol.polrelid) as check_expr
    from pg_policy pol where pol.polrelid = 'public.offers'::regclass`);

  await show('RLS enabled?', `select relname, relrowsecurity from pg_class
    where relname in ('offers','restaurants','ad_slots','app_settings')`);

  await show('table privileges for anon', `select grantee, privilege_type
    from information_schema.role_table_grants
   where table_schema='public' and table_name='offers'
     and grantee in ('anon','authenticated','service_role')`);

  await show('does anon have select on offers?', `select has_table_privilege('anon','public.offers','select') as anon_select`);

  await show('functions mentioning offers', `select p.proname, p.prosecdef as security_definer,
      pg_get_function_identity_arguments(p.oid) as args,
      coalesce(array_to_string(p.proacl, ' | '), '(default acl)') as acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and (p.proname ilike '%offer%' or p.proname ilike '%gift%' or p.proname ilike '%ad%')
   order by p.proname`);

  await show('app_settings', `select key, value from public.app_settings`);

  await show('ad_slots', `select * from public.ad_slots limit 10`);

  await sql.end();
})().catch(e => { console.error('FATAL ' + e.message); process.exit(1); });
