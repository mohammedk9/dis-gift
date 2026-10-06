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

const og = seg('function public.open_daily_gift', 'function public.save_consent');
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

const co = seg('function public.create_order', 'function public.transition_order');
t('order_contact consent REQUIRED', /if not p_consent_order_contact then[\s\S]*?consent_required/.test(co));
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

const tr = seg('function public.transition_order', 'function public.customer_order');
const feeIdx = tr.indexOf("if p_to = 'completed' then");
const ledIdx = tr.indexOf('insert into public.restaurant_ledger');
t('fee block is inside COMPLETED branch only', feeIdx > -1 && ledIdx > feeIdx);
t('ledger insert idempotent (ON CONFLICT DO NOTHING)', /on conflict \(order_id, entry_type\) do nothing/.test(tr));
t('fee snapshotted onto the order', /update public\.orders set platform_fee = v_fee/.test(tr));
t('fee never exceeds order total', /least\(v_fee, ord\.order_total\)/.test(tr));
t('illegal state jumps blocked', /invalid_transition/.test(tr));
t('restaurant cannot act on another restaurant', /is_staff_of\(ord\.restaurant_id\)/.test(tr));
t('net = total - discount - fee', /ord\.order_total - ord\.discount_amount - v_fee/.test(tr));
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
t('platform_fee defaults to 0 (no invented value)', /'platform_fee', '0'::jsonb/.test(seed));
t('seed declares its assumptions', /ASSUMPTION/.test(seed));

// ---- structural completeness: catch truncated CREATE TABLE / files ----
const SRC = ['0001_schema', '0002_rls', '0003_functions', '0004_seed', '0005_site_visitors', '0006_admin_bootstrap'];
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
  // only the schema file is expected to define tables
  if (n === '0001_schema') t('0001_schema: found ' + tables + ' table definitions', tables >= 20);
  else t(n + ': defines no tables (as expected)', tables === 0);

  const lastCode = lines.filter(l => l.trim() && !l.trim().startsWith('--')).pop() || '';
  t(n + ': file ends with a terminated statement', /;\s*$/.test(lastCode));
}

console.log('\n' + (fail === 0 ? '>>> ALL ' + pass + ' INVARIANTS HOLD' : '>>> ' + fail + ' FAILED / ' + pass + ' passed'));
process.exit(fail === 0 ? 0 : 1);