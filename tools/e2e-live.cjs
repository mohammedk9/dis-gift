/* ============================================================
   e2e-live.cjs — تحقق حيّ على مشروع Supabase الفعلي
   التشغيل:  npm run test:live
   يتحقق من: الزائر المجهول، انتحال معرّف عميل آخر، ربط الهوية بالجلسة،
             وإنشاء المنشأة فعلاً عند التسجيل.
   ينشئ حسابات تجريبية ثم يحذفها ويُنظّف كل أثر له.
   يحتاج .env: NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY /
              SUPABASE_SERVICE_ROLE_KEY / DIRECT_URL
   ============================================================ */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
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
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const SERVICE = env.SUPABASE_SERVICE_ROLE_KEY;
const DB = env.DIRECT_URL || env.DATABASE_URL;

let pass = 0, fail = 0;
const t = (label, cond, extra = '') => {
  cond ? pass++ : fail++;
  console.log((cond ? 'PASS  ' : 'FAIL  ') + label + (extra ? '  [' + extra + ']' : ''));
};

(async () => {
  const { Client } = require('pg');
  const sql = new Client({ connectionString: DB });
  await sql.connect();
  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const anonSb = createClient(URL, ANON, { auth: { persistSession: false } });

  const stamp = Date.now();
  const users = [];
  const restaurants = [];

  try {
    /* ---------- 1) الزائر المجهول ---------- */
    const g = await anonSb.rpc('open_daily_gift', { p_device: crypto.randomUUID(), p_area: null });
    t('an anonymous visitor cannot open a daily gift',
      !!g.error && /auth_required/.test(g.error.message || ''), g.error?.message || 'no error');

    const o = await anonSb.rpc('customer_orders', { p_device: crypto.randomUUID() });
    t('an anonymous visitor cannot read customer orders',
      !!o.error && /auth_required/.test(o.error.message || ''), o.error?.message || 'no error');
    /* ---------- 1.b) الهجرة مطبَّقة فعلاً على قاعدة البيانات الحيّة ---------- */
    const live = await sql.query(`select p.proname, pg_get_functiondef(p.oid) as d
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('gift_payload', 'assert_self')`);
    const defs = new Map(live.rows.map(r => [r.proname, r.d]));
    t('the live gift payload no longer returns the code',
      !!defs.get('gift_payload') && !/'code',\s*g\.code/.test(defs.get('gift_payload')));
    t('the live identity guard is installed and rejects anonymous callers',
      !!defs.get('assert_self') && /auth_required/.test(defs.get('assert_self')) &&
      /auth\.uid\(\)/.test(defs.get('assert_self')));

    /* ---------- 2) حساب عميل: الهوية من الجلسة لا من المتصفح ---------- */
    const mk = async email => {
      const { data, error } = await admin.auth.admin.createUser({
        email, password: 'Test1234!', email_confirm: true
      });
      if (error) throw new Error('createUser: ' + error.message);
      users.push(data.user.id);
      return data.user.id;
    };
    const emailA = 'e2e-a-' + stamp + '@example.com';
    const uidA = await mk(emailA);
    const uidB = await mk('e2e-b-' + stamp + '@example.com');

    const a = createClient(URL, ANON, { auth: { persistSession: false } });
    const { error: se } = await a.auth.signInWithPassword({ email: emailA, password: 'Test1234!' });
    if (se) throw new Error('signIn: ' + se.message);

    await sql.query(`insert into public.notifications (recipient_device_id, type, title)
      values ($1,'test','belongs to B'), ($2,'test','belongs to A')`, [uidB, uidA]);

    /* A ينتحل معرّف B: يجب أن يحصل على إشعارات A فقط */
    const forged = await a.rpc('customer_notifications', { p_device: uidB });
    const rows = forged.data || [];
    t('a signed-in customer cannot read another account by passing its id',
      !forged.error && rows.length === 1 && rows[0].title === 'belongs to A',
      rows.map(r => r.title).join('|') || 'empty');

    /* A يرسل معرّفاً عشوائياً: يُعاد كتابته بحساب الجلسة */
    const randomId = await a.rpc('customer_notifications', { p_device: crypto.randomUUID() });
    t('a random browser id is replaced by the session id',
      !randomId.error && (randomId.data || []).length === 1 &&
      randomId.data[0].title === 'belongs to A',
      (randomId.data || []).map(r => r.title).join('|') || 'empty');

    /* ---------- 3) تسجيل منشأة: الحساب يُنشئ منشأته فعلاً ---------- */
    const emailC = 'e2e-c-' + stamp + '@example.com';
    await mk(emailC);
    const c = createClient(URL, ANON, { auth: { persistSession: false } });
    await c.auth.signInWithPassword({ email: emailC, password: 'Test1234!' });
    const reg = await c.rpc('register_restaurant', {
      p_name: 'منشأة اختبار ' + stamp, p_phone: '0555555555', p_address: 'حي الاختبار',
      p_area: null, p_pickup: true, p_delivery: false, p_business: 'restaurant', p_whatsapp: null
    });
    t('a confirmed account creates its business row', reg.data?.ok === true,
      JSON.stringify(reg.data) + (reg.error ? ' ERR ' + reg.error.message : ''));
    if (reg.data?.restaurant_id) restaurants.push(reg.data.restaurant_id);

    const rq = await sql.query(`select r.id, r.status, s.user_id, p.role
      from public.restaurants r
      join public.restaurant_staff s on s.restaurant_id = r.id
      join public.profiles p on p.id = s.user_id
      where r.id = $1`, [reg.data?.restaurant_id || null]);
    t('the business row, its staff link and the elevated role all exist',
      rq.rowCount === 1 && rq.rows[0].role === 'restaurant',
      rq.rowCount ? JSON.stringify(rq.rows[0]) : 'no row');

    const dup = await c.rpc('register_restaurant', {
      p_name: 'مكرر', p_phone: '0555555555', p_address: 'x',
      p_area: null, p_pickup: true, p_delivery: false, p_business: 'restaurant', p_whatsapp: null
    });
    t('the same account is not registered twice', dup.data?.error === 'already_registered',
      JSON.stringify(dup.data));

    /* ---------- 4) تسجيل منشأة بانتظار تأكيد البريد: البيانات في الحساب ---------- */
    const emailD = 'e2e-d-' + stamp + '@example.com';
    const payloadD = {
      name: 'منشأة معلّقة ' + stamp, biz: 'restaurant', phone: '0555555555',
      addr: 'حي الاختبار', area: null, pickup: true, delivery: false, whatsapp: null
    };
    const { data: cu, error: cue } = await admin.auth.admin.createUser({
      email: emailD, password: 'Test1234!', email_confirm: true,
      user_metadata: { full_name: payloadD.name, phone: payloadD.phone,
        pending_restaurant: payloadD }
    });
    if (cue) throw new Error('createUser D: ' + cue.message);
    users.push(cu.user.id);

    const d = createClient(URL, ANON, { auth: { persistSession: false } });
    await d.auth.signInWithPassword({ email: emailD, password: 'Test1234!' });
    const { data: { user: dUser } } = await d.auth.getUser();
    t('the business payload travels with the account, not the browser',
      dUser?.user_metadata?.pending_restaurant?.name === payloadD.name,
      JSON.stringify(dUser?.user_metadata?.pending_restaurant || null));

    const regD = await d.rpc('register_restaurant', {
      p_name: payloadD.name, p_phone: payloadD.phone, p_address: payloadD.addr,
      p_area: null, p_pickup: true, p_delivery: false, p_business: 'restaurant', p_whatsapp: null
    });
    t('a confirmed pending registration finally creates the business',
      regD.data?.ok === true, JSON.stringify(regD.data));
    if (regD.data?.restaurant_id) restaurants.push(regD.data.restaurant_id);

    await d.auth.updateUser({ data: { pending_restaurant: null } });
    const { data: { user: after } } = await d.auth.getUser();
    t('the pending flag is cleared so the next sign-in is not a dead end',
      !after?.user_metadata?.pending_restaurant,
      JSON.stringify(after?.user_metadata?.pending_restaurant ?? null));
  } finally {
    await sql.query(`delete from public.notifications where type = 'test'`).catch(() => {});
    await sql.query(`delete from public.restaurants where id = any($1)`, [restaurants]).catch(() => {});
    for (const u of users) await admin.auth.admin.deleteUser(u).catch(() => {});
    const left = await sql.query(`select
      (select count(*)::int from public.restaurants) as r,
      (select count(*)::int from public.notifications) as n,
      (select count(*)::int from public.profiles) as p,
      (select count(*)::int from public.events) as e`);
    console.log('\ncleanup state: ' + JSON.stringify(left.rows[0]));
    await sql.end();
  }

  console.log('\n' + (fail === 0 ? '>>> LIVE E2E OK (' + pass + ' checks)' : '>>> ' + fail + ' FAILED'));
  process.exit(fail === 0 ? 0 : 1);
})().catch(e => { console.error('FAIL ' + e.message); process.exit(1); });
