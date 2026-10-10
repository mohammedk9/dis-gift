/* فحص ثوابت العمل — Girl verify استاتيكي بلا اتصال */
const fs = require('fs');
const SQL = 'supabase/migrations/0003_functions.sql';
const SCHEMA = 'supabase/migrations/0001_schema.sql';
const RLS = 'supabase/migrations/0002_rls.sql';
const SEED = 'supabase/migrations/0004_seed.sql';
const sql = fs.readFileSync(SQL, 'utf8');
const schema = fs.readFileSync(SCHEMA, 'utf8');
const rls = fs.readFileSync(RLS, 'utf8');
const seg = (a, b) => sql.slice(sql.indexOf(a), b ? sql.indexOf(b) : undefined);
let pass = 0, fail = 0;
const t = (label, cond) => { cond ? pass++ : fail++; console.log((cond ? 'PASS  ' : 'FAIL  ') + label); };

/* ---------- آخر تعريف يفوز ----------
   بعض الدوال تُعاد تعريفها في هجرات أحدث (0007 ثم 0008…)، والفحص يجب أن
   يقرأ النسخة الفعلية لا النسخة القديمة من 0003. */
const LATER = ['0007_whatsapp', '0008_delivery', '0009_consents', '0010_loyalty', '0011_accounts']
  .map(n => fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8')).join('\n');
const ALL = sql + '\n' + LATER;
const fnBody = name => {
  const re = new RegExp('create or replace function public\\.' + name + '\\s*\\(', 'g');
  let m, start = -1;
  while ((m = re.exec(ALL))) start = m.index;
  if (start < 0) return '';
  const end = ALL.indexOf('$$;', start);
  return ALL.slice(start, end < 0 ? ALL.length : end);
};

const og = fnBody('open_daily_gift');
t('one gift per device per day (UNIQUE constraint)', /unique \(device_id, gift_date\)/.test(schema));
t('re-opening returns the SAME gift (no re-roll)', /gift_payload\(new_gift\)/.test(og));
t('race condition handled (unique_violation)', /exception when unique_violation/.test(og));
t('skips offers that hit daily limit', /redeemed_today[\s\S]*?daily_limit/.test(og));
t('skips non-active restaurants', /r\.status = 'active'/.test(og));
t('skips expired / not-yet-started offers', /active_until >= now\(\)/.test(og));
t('respects offer active_hours', /within_active_hours/.test(og));
t('respects customer area', /p_area is null or r\.area_id is null/.test(og));
t('no same-restaurant repeat within 24h', /gift_redemptions gr/.test(og));
t('gift value never below merchant minimum', /if v < p_min then v := p_min/.test(sql));
t('gift deterministic per device+offer+day', /md5\(seed\)/.test(sql));

// ---- gift kinds: not discount-only ----
t('offer_kind enum has 3 kinds (percent/fixed_amount/free_item)',
  /create type public\.offer_kind\s+as enum \('percent','fixed_amount','free_item'\)/.test(schema));
t('business_type enum supports non-food sectors',
  /create type public\.business_type\s+as enum \('restaurant','cafe','salon','store','services','other'\)/.test(schema));
t('free_item gifts require a menu item', /kind = 'free_item' and gift_item_id is not null/.test(schema));
t('open_daily_gift handles free_item', /if picked\.kind = 'free_item' then/.test(og));
t('open_daily_gift caps percent at 100', /picked\.kind = 'percent' and v_disc > 100/.test(og));
t('open_daily_gift stores kind + item on the gift', /gift_kind[\s\S]*?discount_value, gift_item_id, gift_label/.test(og));

const co = fnBody('create_order');
t('order_contact consent is required for DELIVERY only',
  /p_type = 'delivery' and not v_shared then[\s\S]*?consent_required/.test(co));
t('pickup never requires the customer phone',
  !/if p_type = 'pickup' and v_phone is null/.test(co) &&
  !/if p_type = 'pickup' and not v_shared/.test(co));
t('marketing consent is optional', /if p_consent_marketing then/.test(co));
t('rejects already-used gift', /gift_already_used/.test(co));
t('enforces pickup slot', /pickup_slot_required/.test(co));
t('blocks delivery when unsupported', /delivery_not_available/.test(co));
t('gift cannot be redeemed twice (unique gift_id)', /gift_id\s+uuid not null unique/.test(schema));
t('marks gift as redeemed', /set status = 'redeemed'/.test(co));
t('increments offer daily counter', /redeemed_today = case when/.test(co));
t('discount capped at cart subtotal', /least\(v_sub \* g\.discount_value \/ 100, v_sub\)/.test(co));
t('create_order applies fixed_amount as a flat amount',
  /when 'fixed_amount' then least\(g\.discount_value, v_sub\)/.test(co));
t('create_order applies percent as a percentage',
  /when 'percent' then least\(v_sub \* g\.discount_value \/ 100, v_sub\)/.test(co));
t('create_order auto-adds the free item at zero price',
  /if g\.gift_kind = 'free_item' and g\.gift_item_id is not null then/.test(co) &&
  /values \(v_order, it\.id, it\.name, it\.price, 1, 0, 'هدية اليوم'\)/.test(co));
t('free item discount cannot exceed the cart', /greatest\(v_disc, 0\)/.test(co) ||
  /least\(g\.discount_value, v_sub\)/.test(co));

const tr = fnBody('transition_order');
const feeIdx = tr.indexOf("if p_to = 'completed' then");
const ledIdx = tr.indexOf('insert into public.restaurant_ledger');
t('fee block is inside COMPLETED branch only', feeIdx > -1 && ledIdx > feeIdx);
t('ledger insert idempotent (ON CONFLICT DO NOTHING)', /on conflict \(order_id, entry_type\) do nothing/.test(tr));
t('fee snapshotted onto the order', /update public\.orders set platform_fee = v_fee/.test(tr));
t('fee never exceeds the non-delivery part of the order', /least\(v_fee, v_base\)/.test(tr));
t('illegal state jumps blocked', /invalid_transition/.test(tr));
t('restaurant cannot act on another restaurant', /is_staff_of\(ord\.restaurant_id\)/.test(tr));
t('net = order_total - platform_fee (discount is not subtracted twice)',
  /round\(ord\.order_total - v_fee, 2\)/.test(tr));
t('statement upserted on completion', /on conflict \(restaurant_id, statement_period\) do update set/.test(tr));

t('RLS enabled on orders', /alter table public\.orders enable row level security/.test(rls));
// SELECT-level revokes live at the end of 0003_functions.sql
t('anon CANNOT read orders', /revoke all on public\.orders\s+from anon/.test(sql));
t('anon CANNOT read offers (discount stays secret)', /revoke all on public\.offers\s+from anon/.test(sql));
t('anon CANNOT read consents', /revoke all on public\.consents\s+from anon/.test(sql));
t('anon CANNOT write orders', /revoke insert, update, delete on public\.orders\s+from anon/.test(rls));
t('admin can add neighborhoods', /areas_admin_write/.test(rls));
t('restaurant scoped to own restaurant_id', /public\.is_staff_of\(restaurant_id\)/.test(rls));

const seed = fs.readFileSync(SEED, 'utf8');
t('platform_fee is a percentage of the order (1% default)', /'platform_fee', '1'::jsonb/.test(seed));
t('seed declares its assumptions', /ASSUMPTION/.test(seed));

// ---- WhatsApp: قناة توصيل للفاتورة، وليست مساراً يتجاوز النظام ----
const WA = fs.readFileSync('supabase/migrations/0007_whatsapp.sql', 'utf8');
t('restaurants.whatsapp column added',
  /alter table public\.restaurants add column if not exists whatsapp text/.test(WA));
t('whatsapp stored normalised (9665xxxxxxxx)', /\^9665\[0-9\]\{8\}\$/.test(WA));
t('normalisation lives on the server', /create or replace function public\.normalize_whatsapp/.test(WA));
t('normalise returns 966 + local 5xxxxxxxx', /return '966' \|\| v_digits/.test(WA));
t('invalid whatsapp is rejected (not silently dropped)', /invalid_whatsapp/.test(WA));
t('daily gift has a unique short code',
  /daily_gifts_code_key unique \(code\)/.test(WA) && /alter column code set not null/.test(WA));
t('legacy gift codes backfilled with retry (migration cannot fail on collision)',
  /select array_agg\(id\) into v_ids from public\.daily_gifts where code is null/.test(WA) &&
  /exception when unique_violation then/.test(WA));
t('gift code is exposed to the customer', /'code', g\.code/.test(WA));
t('invoice text is built server-side', /function public\.order_invoice_text/.test(WA));
t('invoice shows total, discount and gift code',
  /المطلوب دفعه/.test(WA) && /كود الهدية/.test(WA));
t('invoice numbers come from the order row (server truth)',
  /round\(o\.subtotal, 2\)/.test(WA) && /round\(o\.order_total, 2\)/.test(WA));
t('customer share is scoped to the device', /code = upper\(p_code\) and device_id = p_device/.test(WA));
t('staff share is scoped to the restaurant', /is_staff_of\(o\.restaurant_id\)/.test(WA));
t('whatsapp path never creates an order', !/insert into public\.orders/.test(WA));
// 0007 يقرأ الرسوم في admin_list_restaurants فقط (نسخة موسّعة) — ولا يكتبها أبداً.
t('whatsapp path never writes platform fees',
  !/set platform_fee/.test(WA) && !/insert into public\.restaurant_ledger/.test(WA));
t('0007 does not redefine create_order', !/function public\.create_order/.test(WA));
t('restaurant can disable whatsapp ordering', /whatsapp_orders_enabled/.test(WA));
t('internal invoice builder is not exposed to the API',
  /revoke execute on function public\.order_invoice_text/.test(WA));
t('gift-code generator is not exposed to the API',
  /revoke execute on function public\.new_gift_code/.test(WA));

// ---- التوصيل: رسوم يحددها كل منشأة ويحسبها السيرفر وحده ----
const D8 = fs.readFileSync('supabase/migrations/0008_delivery.sql', 'utf8');
const co8 = fnBody('create_order');
const tr8 = fnBody('transition_order');
const sod = fnBody('set_order_delivery');
const ccp = fnBody('customer_confirm_order_price');

t('restaurants.delivery_fee column added',
  /alter table public\.restaurants add column if not exists delivery_fee numeric/.test(D8));
t('delivery fee cannot be negative (DB constraint)',
  /restaurants_delivery_fee_nonneg/.test(D8) && /check \(delivery_fee >= 0\)/.test(D8));
t('orders carry delivery_fee + price confirmation columns',
  /add column if not exists delivery_fee numeric/.test(D8) &&
  /add column if not exists price_confirmed_at/.test(D8) &&
  /add column if not exists price_confirmed_total/.test(D8));
t('ledger records the delivery fee separately',
  /alter table public\.restaurant_ledger add column if not exists delivery_fee numeric/.test(D8));
t('delivery fee is never accepted from the client (no p_delivery_fee)',
  !/p_delivery_fee/.test(D8));
t('delivery fee comes from the restaurant row',
  /public\.delivery_fee_for\(r\.id\)/.test(co8));
t('order_total = subtotal - discount + delivery_fee',
  /round\(v_sub - v_disc \+ v_fee, 2\)/.test(co8));
t('delivery without an address is rejected', /address_required/.test(co8));
t('platform fee base excludes the delivery fee',
  /ord\.order_total - ord\.delivery_fee/.test(tr8));
t('restaurant keeps the whole delivery fee (net = total - fee)',
  /round\(ord\.order_total - v_fee, 2\)/.test(tr8));
t('fee is written once, inside the COMPLETED branch only',
  (tr8.match(/set platform_fee/g) || []).length === 1 &&
  tr8.indexOf("if p_to = 'completed' then") < tr8.indexOf('set platform_fee'));
t('order cannot be accepted before the customer confirms the price',
  /price_not_confirmed/.test(tr8));
t('confirmation is bound to the exact total the customer saw',
  /price_changed/.test(ccp) && /p_expected_total/.test(ccp));
t('any price change resets the confirmation',
  /price_confirmed_at = case when v_confirm then null else now\(\) end/.test(sod));
t('delivery cannot change after the restaurant started',
  /invalid_delivery_change/.test(sod));
t('switching to delivery clears the stale pickup slot',
  /else null end,   -- التوصيل بلا وقت استلام/.test(sod));
t('orders from before this migration are marked as price-confirmed',
  /where price_confirmed_at is null;/.test(D8));
t('the backfill runs once only (re-running cannot auto-confirm new orders)',
  /if not exists \(select 1 from public\.app_settings where key = 'delivery_backfill_at'\)/.test(D8));
t('delivery fee is capped by the admin setting',
  /delivery_fee_cap/.test(D8) && /delivery_fee_max/.test(D8));
t('cap is enforced on every write path (trigger)',
  /guard_delivery_fee/.test(D8) && /before insert or update on public\.restaurants/.test(D8));
t('merchant cannot set a fee above the cap (explicit error)',
  /delivery_fee_cap', 'cap'/.test(D8));
t('platform revenue stays platform_fee only',
  /'revenue', \(select coalesce\(sum\(platform_fee\),0\)/.test(D8) &&
  /'fees_collected_by_merchants'/.test(D8));
t('invoice prints the delivery fee line', /رسوم التوصيل/.test(D8));
t('internal fee helpers are not exposed to the API',
  /revoke execute on function public\.delivery_fee_for/.test(D8) &&
  /revoke execute on function public\.delivery_fee_cap/.test(D8));
t('new delivery default declares its assumption', /ASSUMPTION/.test(D8));

// ---- الموافقة المقيَّدة بالغرض: الجوال شرط للتوصيل فقط ----
const D9 = fs.readFileSync('supabase/migrations/0009_consents.sql', 'utf8');
const co9 = fnBody('create_order');
const sod9 = fnBody('set_order_delivery');
const ma9 = fnBody('restaurant_marketing_audience');
const ad9 = fnBody('customer_ad');
const cc9 = fnBody('customer_consents');

t('consents carry the purpose text, its source, its time and the order',
  /alter table public\.consents add column if not exists purpose text/.test(D9) &&
  /add column if not exists source text/.test(D9) &&
  /add column if not exists withdrawn_at timestamptz/.test(D9) &&
  /add column if not exists order_id uuid/.test(D9));
t('the exact purpose text shown is the text stored',
  /public\.consent_purpose\('order_contact', r\.id\), 'order', v_order/.test(co9) &&
  /function public\.consent_purpose/.test(D9));
t('purpose wording is editable from app_settings (no hardcoded copy in code)',
  /'consent_purpose_order_contact'/.test(D9) && /'consent_purpose_marketing'/.test(D9));
t('policy version is stored with every consent row',
  /purpose, source, order_id, withdrawn_at\)/.test(D9) &&
  /coalesce\(public\.cfg\('policy_version'\) #>> '\{\}','v1-unverified'\)/.test(co9));
t('a consent decision is never rewritten (new row, no status update, no delete)',
  !/set\s+consent_status/.test(D9) && !/delete from public\.consents/.test(D9));
t('a decline is recorded explicitly as revoked (not inferred from a missing row)',
  /else 'revoked'::public\.consent_status end/.test(co9) &&
  /case when v_shared then null else now\(\) end/.test(co9));
t('the active consent is the newest row for that purpose',
  /order by c\.created_at desc, c\.id desc/.test(D9) &&
  /'active', \(c\.consent_status = 'granted'\)/.test(cc9));
t('the customer sees active consents and the full history separately',
  /'consents', v_active, 'history', v_history/.test(cc9));

t('delivery is rejected without a phone number', /phone_required/.test(co9) &&
  /orders_delivery_phone_required/.test(D9));
t('delivery is rejected without an explicit share consent', /consent_required/.test(co9));
t('switching to delivery re-checks phone + consent on the server',
  /if not o\.phone_shared then[\s\S]*?consent_required/.test(sod9) &&
  /coalesce\(trim\(o\.customer_phone\), ''\) = ''/.test(sod9));
t('phone sharing can be changed by the device owner only',
  /code = upper\(p_code\) and device_id = p_device for update/.test(fnBody('set_order_phone')));
t('phone sharing is a state on the order, not just a log row',
  /add column if not exists phone_shared boolean/.test(D9) &&
  /'phone_shared', o\.phone_shared/.test(fnBody('restaurant_orders')));
t('the restaurant only ever sees a masked number without consent',
  /else public\.mask_phone\(o\.customer_phone\) end/.test(fnBody('restaurant_orders')) &&
  /function public\.mask_phone/.test(D9));
t('the invoice never prints the phone without consent',
  /case when o\.phone_shared then o\.customer_phone/.test(fnBody('order_invoice_text')) &&
  /'غير مُشارَك'/.test(fnBody('order_invoice_text')));
t('staff cannot send the invoice to a customer who did not share',
  /if not o\.phone_shared then[\s\S]*?phone_not_shared/.test(fnBody('staff_order_share')));
t('the customer phone column is not readable from the browser',
  /revoke select on public\.orders from anon, authenticated/.test(D9) &&
  !/customer_phone/.test((D9.match(/grant select \([\s\S]*?\)\s*on public\.orders to authenticated/) || [''])[0]));
t('the phone backfill runs once only',
  /if not exists \(select 1 from public\.app_settings where key = 'consents_backfill_at'\)/.test(D9));

t('no marketing content without an active marketing consent',
  /if not public\.consent_active\(p_device, p_restaurant, 'marketing'\) then[\s\S]*?no_marketing_consent/.test(ad9));
t('the marketing audience exposes a count only (no phones, no device ids)',
  /'count', v_count/.test(ma9) && !/'device_id'/.test(ma9) && !/'phone'/.test(ma9));
t('marketing consent is never a condition for an order',
  !/p_consent_marketing then[\s\S]{0,120}return jsonb_build_object\('ok', false/.test(co9));

// ---- النقاط: استحقاق وعرض فقط، بلا استبدال ولا أثر مالي ----
const D10 = fs.readFileSync('supabase/migrations/0010_loyalty.sql', 'utf8');
const tr10 = fnBody('transition_order');
const sg10 = fnBody('staff_grant_points');
const sc10 = fnBody('staff_order_by_code');

t('points ledger is one row per order (unique order_id)',
  /order_id\s+uuid unique references public\.orders/.test(D10));
t('points ledger is append-only (guard blocks delete and amount changes)',
  /function public\.guard_points_ledger/.test(D10) &&
  /if tg_op = 'DELETE' then/.test(D10) && /new\.points <> old\.points/.test(D10));
t('the only allowed ledger update is pending → applied/cancelled',
  /old\.status <> 'pending' or new\.status not in \('applied','cancelled'\)/.test(D10));
t('the balance is a sum, never a stored counter',
  /select coalesce\(sum\(points\), 0\) into v_balance/.test(D10) &&
  !/add column if not exists points_balance/.test(D10));
t('points are credited only when the order completes',
  tr10.indexOf("set status = 'applied', applied_at = now()") >
    tr10.indexOf('insert into public.restaurant_ledger') &&
  /and status = 'pending'/.test(tr10));
t('a cancelled order never gets points credited',
  /if p_to in \('cancelled','no_show'\) then[\s\S]*?set status = 'cancelled'/.test(tr10));
t('granting points is refused on a cancelled order',
  /if o\.status in \('cancelled','no_show'\) then[\s\S]*?invalid_transition/.test(sg10));
t('points cannot be granted twice on the same order',
  /points_already_granted/.test(sg10) && /exception when unique_violation then/.test(sg10));
t('points cannot be granted when the restaurant disabled them',
  /if not r\.points_enabled then[\s\S]*?points_disabled/.test(sg10));
t('a non-positive amount is rejected instead of silently ignored',
  /if v_points is null or v_points <= 0 then[\s\S]*?points_invalid/.test(sg10));
t('the admin ceiling is enforced on every write path',
  /function public\.guard_points_settings/.test(D10) &&
  /before insert or update on public\.restaurants/.test(D10) &&
  /v_cap := case when r\.points_max_per_order > 0/.test(sg10));
t('the ceiling is an editable setting, not a hardcoded number',
  /'points_hard_cap'/.test(D10) && /function public\.points_hard_cap/.test(D10));
t('only staff_grant_points writes the ledger, and clients cannot read it',
  (D10.match(/insert into public\.points_ledger/g) || []).length === 1 &&
  /revoke all on public\.points_ledger from anon, authenticated/.test(D10) &&
  /alter table public\.points_ledger enable row level security/.test(D10) &&
  !/create policy[\s\S]{0,60}points_ledger/.test(D10));
t('internal points helpers are not exposed to the API',
  /revoke execute on function public\.points_hard_cap/.test(D10) &&
  /revoke execute on function public\.guard_points_ledger/.test(D10));
t('points are absent from the money maths (fees and net unchanged)',
  /least\(v_fee, v_base\)/.test(tr10) && /round\(ord\.order_total - v_fee, 2\)/.test(tr10) &&
  /'revenue', \(select coalesce\(sum\(platform_fee\),0\)/.test(D10));
t('points are accrual/display only — no redemption path exists',
  /'redeemable', false/.test(D10) && !/points_redeem|redeem_points/.test(D10));
t('the fee is a share of the order value, never a flat amount',
  /round\(v_base \* coalesce\(\(public\.cfg\('platform_fee'\)[\s\S]*?\) \/ 100, 2\)/.test(tr10));
t('daily-gift unique constraint is re-runnable (guarded, not exception-based)',
  /if not exists \(\s*select 1 from pg_constraint[\s\S]*?conname = 'daily_gifts_code_key'/.test(WA));

t('the barcode reuses the order code (no second code is generated)',
  /'code', o\.code/.test(sc10) && !/barcode_code|new_barcode_code/.test(D10));
t('an unknown or malformed scan code is rejected explicitly',
  /invalid_order_code/.test(sc10) && /\^\[0-9A-F\]\{6\}\$/.test(sc10));
t('the scan lookup is scoped to the staff restaurant',
  /where code = v_code and restaurant_id = v_id/.test(sc10));
t('the scan payload shows the same masked-phone rule as the order list',
  /else public\.mask_phone\(o\.customer_phone\) end/.test(sc10));

// ---- 0011: الهوية على الحساب، وكود الهدية لا يُسلَّم لزائر ----
console.log('\n--- account identity (0011) ---');
const D11 = fs.readFileSync('supabase/migrations/0011_accounts.sql', 'utf8');
const CUSTOMER_RPC = ['open_daily_gift', 'create_order', 'customer_order', 'customer_orders',
  'customer_notifications', 'customer_consents', 'set_consent', 'customer_points',
  'customer_ad', 'customer_confirm_order_price', 'set_order_delivery', 'set_order_phone',
  'customer_order_share'];

t('identity comes from the session, never from the value the browser sent',
  /public\.assert_self\(p_device uuid\)[\s\S]*?v_uid uuid := auth\.uid\(\)/.test(D11));
t('an anonymous caller is rejected explicitly instead of acting as a device',
  /if v_uid is null then\s*\r?\n\s*raise exception 'auth_required'/.test(D11));
t('every customer entry point overwrites the browser-supplied id',
  CUSTOMER_RPC.every(n => new RegExp(
    'create or replace function public\\.' + n + '\\b[\\s\\S]*?p_device := public\\.assert_self\\(p_device\\);'
  ).test(D11)));
t('the gift/order rows stay keyed by that id, so the same account cannot take two gifts',
  /p_device := public\.assert_self\(p_device\)/.test(D11) &&
  /unique \(device_id, gift_date\)/.test(schema));
t('orders.user_id is finally populated from the same account id',
  /create or replace function public\.sync_order_user_id/.test(D11) &&
  /new\.user_id := new\.device_id/.test(D11) &&
  /create trigger trg_orders_sync_user/.test(D11));
t('the gift code is not returned at the moment the gift is opened',
  !/'code',\s*g\.code/.test(D11.slice(D11.indexOf('create or replace function public.gift_payload'))));

// ---- الواجهة: لا هوية في المتصفح ولا كود للزائر ----
console.log('\n--- account identity (frontend) ---');
const rd = f => fs.readFileSync(f, 'utf8');
const CORE = rd('assets/js/core.js');
const UIF = rd('assets/js/ui.js');
const FLOWS = rd('assets/js/auth-flows.js');
const GUARDED = ['gift.html', 'menu.html', 'checkout.html', 'order.html',
  'orders.html', 'notices.html', 'account.html'];

t('the browser no longer mints a customer identity',
  !/localStorage\.setItem\('hg_device'/.test(CORE) && !/export function deviceId/.test(CORE));
t('the identity is adopted from the session before guarded calls',
  /export async function adoptIdentity/.test(CORE) && /await adoptIdentity\(\)/.test(UIF));
t('every customer page requires an account (no code or order for a visitor)',
  GUARDED.every(f => /guardCustomer\(\)/.test(rd(f))));
t('no customer page still sends a browser-stored id',
  !GUARDED.some(f => /\bdeviceId\(/.test(rd(f))));
t('the gift code is never rendered to the customer',
  !/g\.code\b/.test(rd('gift.html')) && !/gift\.gift\.code/.test(rd('menu.html')));
t('a stale cached gift cannot leak a previously stored code',
  /const stripCode/.test(CORE) && /delete copy\.gift\.code/.test(CORE));
t('the business payload lives on the account, not in localStorage',
  !/hg_pending_restaurant'\]?,?\s*=/.test(FLOWS) &&
  /\[META_KEY\]: \{ \.\.\.payload/.test(FLOWS) &&
  /user_metadata/.test(FLOWS) && /sb\.auth\.updateUser/.test(FLOWS));
t('the confirmation link works from any browser (no PKCE verifier needed)',
  /flowType: 'implicit'/.test(CORE) && !/flowType: 'pkce'/.test(CORE));
t('a failed sign-in distinguishes an unconfirmed email and offers a resend',
  /email_not_confirmed/.test(rd('login.html')) && /sb\.auth\.resend/.test(rd('login.html')));
t('a wrong audience tab gives a way out instead of a dead end',
  /showAudienceMismatch/.test(rd('login.html')) && /registerUrl\('business'\)/.test(rd('login.html')));
t('a signed-in customer can finish registering a business on the same account',
  /if \(existing\)/.test(rd('register.html')) && /registerRestaurant\(\{/.test(rd('register.html')));
t('switching accounts on one browser does not expose the previous account data',
  /sessionStorage\.getItem\('hg_actor_seen'\)/.test(CORE) &&
  /previous !== next/.test(CORE));
t('the profile is read from and written to the account',
  /from\('profiles'\)/.test(rd('account.html')) && /update\(\{ full_name/.test(rd('account.html')));
t('signing out is possible and only ends the session',
  /sb\.auth\.signOut\(\)/.test(rd('account.html')));
t('checkout takes customer details from the account, not from localStorage alone',
  /myProfile\?\.full_name/.test(rd('checkout.html')) && /profilePhone/.test(rd('checkout.html')));
t('the homepage account menu tracks the session (guest vs. member)',
  /accountGuest/.test(rd('index.html')) && /accountMember/.test(rd('index.html')) &&
  /renderAccountState/.test(rd('index.html')) && /sb\.auth\.onAuthStateChange/.test(rd('index.html')));



// ---- structural completeness: catch truncated CREATE TABLE / files ----
const SRC = ['0001_schema', '0002_rls', '0003_functions', '0004_seed', '0005_site_visitors',
  '0006_admin_bootstrap', '0007_whatsapp', '0008_delivery', '0009_consents', '0010_loyalty',
  '0011_accounts'];
console.log('\n--- structural completeness ---');
for (const n of SRC) {
  const raw = fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8');
  const lines = raw.split(/\r?\n/);          // normalise CRLF

  let tables = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\s*create table (?:if not exists )?public\.(\w+)\s*\(\s*$/);
    if (!m) continue;
    tables++;
    const name = m[1];
    let closed = false;
    for (let j = i + 1; j < lines.length; j++) {
      if (/^\s*create (table|function|index|policy|type|trigger)\b/.test(lines[j])) break;
      if (/^\s*\);\s*$/.test(lines[j])) { closed = true; break; }
    }
    t(n + ': table ' + name + ' complete', closed);
  }
  // only these files are expected to define tables (new tables come with their migration)
  const TABLE_FILES = { '0001_schema': 20, '0010_loyalty': 1 };
  if (n in TABLE_FILES) t(n + ': found ' + tables + ' table definitions (>= ' + TABLE_FILES[n] + ')',
    tables >= TABLE_FILES[n]);
  else t(n + ': defines no tables (as expected)', tables === 0);

  const lastCode = lines.filter(l => l.trim() && !l.trim().startsWith('--')).pop() || '';
  t(n + ': file ends with a terminated statement', /;\s*$/.test(lastCode));
}

console.log('\n' + (fail === 0 ? '>>> ALL ' + pass + ' INVARIANTS HOLD' : '>>> ' + fail + ' FAILED / ' + pass + ' passed'));
process.exit(fail === 0 ? 0 : 1);