-- ============================================================
-- هدية | Lean MVP — 0003_functions.sql
-- كل منطق الأعمال هنا. الواجهة لا تقرّر شيئاً.
-- ============================================================

create or replace function public.cfg(p_key text) returns jsonb
language sql stable as $$
  select coalesce((select value from public.app_settings where key = p_key), 'null'::jsonb);
$$;

create or replace function public.now_riyadh() returns timestamptz
language sql stable as $$ select now() at time zone 'Asia/Riyadh'; $$;

create or replace function public.today_riyadh() returns date
language sql stable as $$ select (now() at time zone 'Asia/Riyadh')::date; $$;

-- هل الوقت الحالي ضمن نطاق ساعات العمل؟  '{}' = طول اليوم
create or replace function public.is_open_now(p_hours jsonb) returns boolean
language plpgsql stable as $$
declare t time := (now() at time zone 'Asia/Riyadh')::time; d text := to_char(now() at time zone 'Asia/Riyadh','dy');
    slot jsonb;
begin
  if p_hours is null or p_hours = '{}'::jsonb then return true; end if;
  slot := p_hours -> d;
  if slot is null then return false; end if;
  return (t::text)::time >= (slot->>'open')::time and (t::text)::time <= (slot->>'close')::time;
exception when others then return true;
end $$;

-- نطاق ساعات العرض: '[]' = طول اليوم
create or replace function public.within_active_hours(p_hours jsonb) returns boolean
language plpgsql stable as $$
declare t time := (now() at time zone 'Asia/Riyadh')::time; w jsonb;
begin
  if p_hours is null or jsonb_array_length(p_hours) = 0 then return true; end if;
  for w in select * from jsonb_array_elements(p_hours) loop
    if (t::text)::time >= (w->>'start')::time and (t::text)::time <= (w->>'end')::time then
      return true;
    end if;
  end loop;
  return false;
exception when others then return true;
end $$;

-- ---------- اختيار قيمة الخصم داخل النطاق (مضمونة >= min) ----------
-- deterministic: نفس الجهاز + نفس العرض + نفس اليوم => نفس القيمة
create or replace function public.pick_discount(
  p_offer_id uuid, p_min numeric, p_max numeric,
  p_device uuid, p_date date, p_step numeric
) returns numeric
language plpgsql immutable as $$
declare seed text := p_device::text || p_offer_id::text || p_date::text;
    h bigint;
    span numeric := greatest(p_max - p_min, 0);
    v numeric;
begin
  -- أول بتات md5 كعدد صحيح
  h := ('x' || substr(md5(seed), 1, 12))::bit(48)::bigint;
  if span = 0 then return round(p_min, 2); end if;
  v := p_min + ( (h % 100000)::numeric / 100000 ) * span;
  v := round(v / greatest(p_step, 0.01)) * greatest(p_step, 0.01);
  if v < p_min then v := p_min; end if;      -- ضمان الحد الأدنى
  if v > p_max then v := p_max; end if;
  return round(v, 2);
-- عدد العروض المتبقية لهذا العرض اليوم
create or replace function public.offer_remaining(p_offer_id uuid) returns int
language sql stable as $$
  select greatest(coalesce(p.daily_limit,0) - case when p.redeemed_on = public.today_riyadh()
       then p.redeemed_today else 0 end, 0)
  from public.offers p where p.id = p_offer_id;
$$;

-- حمولة الهدية للعرض (تُرجع للعميل بعد الفتح فقط)
create or replace function public.gift_payload(p_gift uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g record; r record; o record;
begin
  select * into g from public.daily_gifts where id = p_gift;
  if not found then return jsonb_build_object('ok', false, 'error', 'gift_not_found'); end if;

  select id, name, description, logo_url, cover_url, phone, address,
         pickup_enabled, delivery_enabled, prep_time_min, area_id, city
    into r from public.restaurants where id = g.restaurant_id;
  select title, description, active_until into o from public.offers where id = g.offer_id;

  return jsonb_build_object(
    'ok', true,
    'gift', jsonb_build_object(
      'id', g.id, 'discount', g.discount_value, 'status', g.status,
      'opened_at', g.opened_at, 'redeemed', (g.status = 'redeemed')
    ),
    'restaurant', jsonb_build_object(
      'id', r.id, 'name', r.name, 'description', r.description,
      'logo_url', r.logo_url, 'cover_url', r.cover_url,
      'phone', r.phone, 'address', r.address, 'city', r.city,
      'pickup_enabled', r.pickup_enabled, 'delivery_enabled', r.delivery_enabled,
      'prep_time_min', r.prep_time_min
    ),
-- ============================================================
-- 1) هدية اليوم
-- ============================================================
create or replace function public.open_daily_gift(p_device uuid, p_area int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_today date    := public.today_riyadh();
  v_step  numeric := coalesce((public.cfg('discount_step') #>> '{}')::numeric, 1);
  v_floor numeric := coalesce((public.cfg('min_discount_floor') #>> '{}')::numeric, 0);
  v_min_eff numeric;
  o record; picked record; v_disc numeric; new_gift uuid; v_count int;
begin
  if p_device is null then
    return jsonb_build_object('ok', false, 'error', 'device_required');
  end if;

  -- هل فُتحت هدية اليوم سابقاً؟ القيد unique(device_id, gift_date) يمنع أكثر من واحدة
  if exists (select 1 from public.daily_gifts where device_id = p_device and gift_date = v_today) then
    select id into new_gift from public.daily_gifts
     where device_id = p_device and gift_date = v_today;
    return public.gift_payload(new_gift);
  end if;

  -- المرشّحون: متاح ضمن الشروط
  select of.*, r.name as r_name
    into picked
    from public.offers of
    join public.restaurants r on r.id = of.restaurant_id
   where of.is_enabled
     and r.status = 'active'
     and (of.active_from  is null or of.active_from  <= now())
     and (of.active_until is null or of.active_until >= now())
     and public.within_active_hours(of.active_hours)
     and (p_area is null or r.area_id is null or r.area_id = p_area)
     and case when of.redeemed_on = v_today then of.redeemed_today else 0 end < of.daily_limit
     and not exists (
       select 1 from public.gift_redemptions gr
        where gr.device_id = p_device and gr.restaurant_id = of.restaurant_id
          and gr.redeemed_at >= (public.now_riyadh() - interval '1 day'))
   order by md5(p_device::text || of.id::text || v_today::text)
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_offers_available');
  end if;

  -- قيمة الخصم: داخل النطاق، ولا تقل عن الحد الأدنى العام
  v_min_eff := greatest(picked.min_discount, v_floor);
  if v_min_eff > picked.max_discount then v_min_eff := picked.max_discount; end if;
  v_disc := public.pick_discount(picked.id, v_min_eff, picked.max_discount, p_device, v_today, v_step);

  insert into public.daily_gifts (device_id, gift_date, offer_id, restaurant_id, discount_value)
  values (p_device, v_today, picked.id, picked.restaurant_id, v_disc)
  returning id into new_gift;
-- ============================================================
-- 2) حفظ الموافقة (سجل مستقل لكل نوع)
-- ============================================================
create or replace function public.save_consent(
  p_device uuid, p_restaurant uuid, p_type public.consent_type,
  p_status public.consent_status
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ver text := coalesce(public.cfg('policy_version') #>> '{}', 'v1-unverified');
begin
  insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)
  values (p_device, p_restaurant, p_type, p_status, v_ver);
  return jsonb_build_object('ok', true, 'policy_version', v_ver);
end $$;

-- ============================================================
-- 3) تسجيل حدث (menu_view / cart_created)
-- ============================================================
create or replace function public.log_event(
  p_type text, p_device uuid default null, p_restaurant uuid default null,
  p_gift uuid default null, p_order uuid default null, p_meta jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = public as $$
  insert into public.events (type, device_id, restaurant_id, gift_id, order_id, meta)
  values (p_type, p_device, p_restaurant, p_gift, p_order, coalesce(p_meta,'{}'::jsonb));
$$;
-- ============================================================
-- 4) إنشاء طلب من هدية
-- ============================================================
create or replace function public.create_order(
  p_device uuid, p_gift uuid, p_type public.order_type,
  p_items jsonb,
  p_name text, p_phone text,
  p_area int default null, p_address text default null,
  p_slot time default null, p_note text default null,
  p_consent_order_contact boolean default false,
  p_consent_marketing boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record; r record; it record; q jsonb;
  v_sub numeric := 0; v_disc numeric := 0; v_total numeric := 0;
  v_code text; v_order uuid;
begin
  select * into g from public.daily_gifts
   where id = p_gift and device_id = p_device for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'gift_not_found'); end if;
  if g.status <> 'opened' then return jsonb_build_object('ok', false, 'error', 'gift_already_used'); end if;

  -- موافقة التواصل شرط لازم للتنفيذ. التسويق ليس شرطاً.
  if not p_consent_order_contact then
    return jsonb_build_object('ok', false, 'error', 'consent_required');
  end if;

  select * into r from public.restaurants where id = g.restaurant_id;
  if r.status <> 'active' then return jsonb_build_object('ok', false, 'error', 'restaurant_unavailable'); end if;
  if p_type = 'delivery' and not r.delivery_enabled then
    return jsonb_build_object('ok', false, 'error', 'delivery_not_available');
  end if;
  if p_type = 'pickup' and not r.pickup_enabled then
    return jsonb_build_object('ok', false, 'error', 'pickup_not_available');
  end if;
  if p_type = 'pickup' and p_slot is null then
    return jsonb_build_object('ok', false, 'error', 'pickup_slot_required');
  end if;

  for q in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    select * into it from public.menu_items
     where id = (q->>'item_id')::uuid and restaurant_id = r.id and is_available;
    if found then v_sub := v_sub + (it.price * greatest((q->>'qty')::int, 1)); end if;
  end loop;

  if v_sub <= 0 then return jsonb_build_object('ok', false, 'error', 'empty_cart'); end if;
  if v_sub < r.min_order_total then
    return jsonb_build_object('ok', false, 'error', 'below_min_order');
  end if;

  v_disc  := round(least(v_sub * g.discount_value / 100, v_sub), 2);
  v_total := round(v_sub - v_disc, 2);
  v_code  := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

  insert into public.orders
    (code, restaurant_id, device_id, gift_id, order_type, status,
     subtotal, discount_amount, order_total, platform_fee,
     customer_name, customer_phone, area_id, address, pickup_slot, note)
  values
    (v_code, r.id, p_device, g.id, p_type, 'new',
     v_sub, v_disc, v_total, 0,
     p_name, p_phone, p_area, p_address, p_slot, p_note)
  returning id into v_order;

  for q in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    select * into it from public.menu_items
     where id = (q->>'item_id')::uuid and restaurant_id = r.id and is_available;
    if found then
      insert into public.order_items
        (order_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total, note)
      values (v_order, it.id, it.name, it.price, greatest((q->>'qty')::int,1),
              it.price * greatest((q->>'qty')::int,1), q->>'note');
    end if;
  end loop;

  insert into public.gift_redemptions (gift_id, order_id, device_id, restaurant_id, discount_value)
  values (g.id, v_order, p_device, r.id, v_disc);
  update public.daily_gifts set status = 'redeemed' where id = g.id;
  update public.offers set redeemed_today = case when redeemed_on = public.today_riyadh()
      then redeemed_today + 1 else 1 end,
      redeemed_on = public.today_riyadh()
   where id = g.offer_id;

  insert into public.order_events (order_id, to_status, actor_role)
  values (v_order, 'new', 'customer');

  insert into public.events (device_id, restaurant_id, gift_id, order_id, type, meta)
  values (p_device, r.id, g.id, v_order, 'order_created', jsonb_build_object('total', v_total));

  insert into public.notifications (restaurant_id, order_id, type, title, body)
-- ============================================================
-- 5) دورة حالة الطلب — الرسوم فقط عند COMPLETED
--    new → accepted → preparing → ready → completed
--    أي حالة أخرى → cancelled | no_show  (بلا رسوم)
-- ============================================================
create or replace function public.transition_order(
  p_order uuid, p_to public.order_status, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ord record; frm public.order_status; actor public.app_role;
  v_fee numeric; v_period text; v_net numeric;
begin
  select * into ord from public.orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  if not (public.is_staff_of(ord.restaurant_id) or public.is_admin()) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  actor := case when public.is_admin() and not exists
    (select 1 from public.restaurant_staff where restaurant_id = ord.restaurant_id and user_id = auth.uid())
    then 'admin'::public.app_role else 'restaurant'::public.app_role end;

  frm := ord.status;

  -- آلة الحالات
  if not (
       (frm = 'new'      and p_to in ('accepted','cancelled')) or
       (frm = 'accepted' and p_to in ('preparing','cancelled','no_show')) or
       (frm = 'preparing' and p_to in ('ready','cancelled','no_show')) or
       (frm = 'ready'    and p_to in ('completed','cancelled','no_show'))
     ) then
    return jsonb_build_object('ok', false, 'error', 'invalid_transition', 'from', frm, 'to', p_to);
  end if;

  update public.orders set
    status = p_to,
    accepted_at   = case when p_to = 'accepted'   then now() else accepted_at end,
    ready_at      = case when p_to = 'ready'      then now() else ready_at end,
    completed_at  = case when p_to = 'completed'  then now() else completed_at end,
    cancelled_at  = case when p_to in ('cancelled','no_show') then now() else cancelled_at end,
    cancel_reason = case when p_to in ('cancelled','no_show') then p_note else cancel_reason end,
    completion_code = case when p_to = 'completed'
                           then coalesce(completion_code,
                             upper(substr(md5(random()::text || clock_timestamp()::text),1,4)))
                           else completion_code end
   where id = p_order;

  insert into public.order_events (order_id, from_status, to_status, actor_role, actor_id, note)
  values (p_order, frm, p_to, actor, auth.uid(), p_note);

  -- إشعار العميل
  if p_to = 'accepted' then
    insert into public.notifications (recipient_device_id, restaurant_id, order_id, type, title, body)
    values (ord.device_id, ord.restaurant_id, p_order, 'order_accepted', 'تم قبول طلبك', 'طلب ' || ord.code);
  elsif p_to = 'ready' then
    insert into public.notifications (recipient_device_id, restaurant_id, order_id, type, title, body)
    values (ord.device_id, ord.restaurant_id, p_order, 'order_ready', 'طلبك جاهز', 'طلب ' || ord.code);
  elsif p_to = 'completed' then
    insert into public.notifications (recipient_device_id, restaurant_id, order_id, type, title, body)
    values (ord.device_id, ord.restaurant_id, p_order, 'order_completed', 'تم تأكيد طلبك', 'طلب ' || ord.code);
  elsif p_to in ('cancelled','no_show') then
    insert into public.notifications (recipient_device_id, restaurant_id, order_id, type, title, body)
    values (ord.device_id, ord.restaurant_id, p_order, 'order_cancelled', 'تم إلغاء الطلب', 'طلب ' || ord.code);
  end if;

  -- === الرسوم: عند COMPLETED فقط ===
  if p_to = 'completed' then
    v_fee := coalesce((public.cfg('platform_fee') #>> '{}')::numeric, 0);
    v_fee := least(v_fee, ord.order_total);          -- لا رسوم أكبر من الطلب
    v_net  := round(ord.order_total - ord.discount_amount - v_fee, 2);
    v_period := to_char(public.now_riyadh(), 'YYYY-MM');

    update public.orders set platform_fee = v_fee where id = p_order;

    insert into public.restaurant_ledger
      (restaurant_id, order_id, order_total, discount_amount, platform_fee,
       restaurant_net, statement_period)
    values (ord.restaurant_id, p_order, ord.order_total, ord.discount_amount,
            v_fee, v_net, v_period)
    on conflict (order_id, entry_type) do nothing;   -- تكرار غير ممكن

    insert into public.monthly_statements
      (restaurant_id, statement_period, completed_orders, total_order_value,
       total_discounts, total_platform_fees, outstanding)
    values (ord.restaurant_id, v_period, 1, ord.order_total, ord.discount_amount, v_fee, v_fee)
    on conflict (restaurant_id, statement_period) do update set
      completed_orders    = public.monthly_statements.completed_orders + 1,
      total_order_value   = public.monthly_statements.total_order_value   + excluded.total_order_value,
      total_discounts     = public.monthly_statements.total_discounts     + excluded.total_discounts,
      total_platform_fees = public.monthly_statements.total_platform_fees + excluded.total_platform_fees,
      outstanding         = public.monthly_statements.outstanding         + excluded.outstanding,
      generated_at        = now();

    insert into public.events (device_id, restaurant_id, gift_id, order_id, type, meta)
    values (ord.device_id, ord.restaurant_id, ord.gift_id, p_order, 'order_completed',
            jsonb_build_object('total', ord.order_total, 'fee', v_fee));
  end if;

  return jsonb_build_object('ok', true, 'status', p_to, 'platform_fee',
                            case when p_to = 'completed' then v_fee else 0 end);
-- ============================================================
-- 6) طلب العميل: حالة + سجل (لجهازه فقط)
-- ============================================================
create or replace function public.customer_order(p_device uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; r record;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;
  select name, phone, address, logo_url into r from public.restaurants where id = o.restaurant_id;
  return jsonb_build_object(
    'ok', true,
    'order', jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'order_type', o.order_type,
      'subtotal', o.subtotal, 'discount', o.discount_amount, 'total', o.order_total,
      'pickup_slot', o.pickup_slot, 'note', o.note, 'created_at', o.created_at,
      'completed_at', o.completed_at, 'customer_name', o.customer_name,
      'customer_phone', o.customer_phone, 'address', o.address,
      'payment_note', 'الدفع يتم مباشرة للمطعم.'
    ),
    'restaurant', jsonb_build_object('name', r.name, 'phone', r.phone,
                                     'address', r.address, 'logo_url', r.logo_url),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                 'name', name_snapshot, 'qty', qty, 'line_total', line_total) order by name_snapshot),
               '[]'::jsonb)
              from public.order_items where order_id = o.id),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object(
                 'status', to_status, 'note', note, 'at', created_at) order by created_at),
               '[]'::jsonb)
              from public.order_events where order_id = o.id)
  );
end $$;

create or replace function public.customer_orders(p_device uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', o.code, 'status', o.status, 'total', o.order_total,
           'order_type', o.order_type, 'created_at', o.created_at,
           'restaurant', r.name, 'logo_url', r.logo_url) order by o.created_at desc), '[]'::jsonb)
  from public.orders o join public.restaurants r on r.id = o.restaurant_id
  where o.device_id = p_device;
$$;

create or replace function public.customer_notifications(p_device uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'type', type, 'title', title, 'body', body,
           'is_read', is_read, 'at', created_at) order by created_at desc), '[]'::jsonb)
  from (select * from public.notifications
         where recipient_device_id = p_device order by created_at desc limit 20) n;
$$;

create or replace function public.customer_consents(p_device uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'restaurant', r.name, 'type', c.consent_type, 'status', c.consent_status,
           'policy_version', c.policy_version, 'at', c.created_at) order by c.created_at desc), '[]'::jsonb)
  from public.consents c left join public.restaurants r on r.id = c.restaurant_id
  where c.device_id = p_device;
$$;

create or replace function public.active_areas()
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'city', city)
             order by sort_order, name), '[]'::jsonb)
  from public.areas where is_active;
$$;

create or replace function public.restaurant_menu(p_restaurant uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'restaurant', (select jsonb_build_object('id', id, 'name', name, 'description', description,
        'logo_url', logo_url, 'cover_url', cover_url, 'phone', phone, 'address', address,
        'pickup_enabled', pickup_enabled, 'delivery_enabled', delivery_enabled,
        'prep_time_min', prep_time_min, 'min_order_total', min_order_total)
      from public.restaurants where id = p_restaurant),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'name', c.name, 'items',
        coalesce((select jsonb_agg(jsonb_build_object(
            'id', i.id, 'name', i.name, 'description', i.description,
            'price', i.price, 'image_url', i.image_url, 'is_available', i.is_available)
          order by i.sort_order) from public.menu_items i
          where i.category_id = c.id and i.is_available), '[]'::jsonb)) order by c.sort_order, c.name), '[]'::jsonb)
      from public.menu_categories c where c.restaurant_id = p_restaurant and c.is_active),
    'slots', (select coalesce(jsonb_agg(to_char(s.slot_time,'HH24:MI') order by s.slot_time), '[]'::jsonb)
      from public.pickup_slots s where s.restaurant_id = p_restaurant and s.is_active)
  );
-- ============================================================
-- 7) تسجيل مطعم جديد
-- ============================================================
create or replace function public.register_restaurant(
  p_name text, p_phone text, p_address text, p_area int,
  p_description text default null, p_pickup boolean default true,
  p_delivery boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_slug text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'auth_required'); end if;
  if exists (select 1 from public.restaurant_staff where user_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'already_registered');
  end if;
  v_slug := regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g');
  insert into public.restaurants (name, slug, phone, address, area_id, description,
                                  pickup_enabled, delivery_enabled, status, owner_id)
  values (p_name, v_slug || '-' || substr(md5(v_uid::text),1,4), p_phone, p_address, p_area,
          p_description, p_pickup, p_delivery, 'pending', v_uid)
  returning id into v_id;
  insert into public.restaurant_staff (restaurant_id, user_id, role)
  values (v_id, v_uid, 'owner');
  update public.profiles set role = 'restaurant', phone = coalesce(phone, p_phone),
       full_name = coalesce(full_name, p_name) where id = v_uid;
  return jsonb_build_object('ok', true, 'restaurant_id', v_id, 'status', 'pending');
end $$;

-- ============================================================
-- 8) لوحة المطعم
-- ============================================================
create or replace function public.restaurant_dashboard(p_days int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; since timestamptz := now() - (coalesce(p_days,30) || ' days')::interval;
begin
  select restaurant_id into v_id from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  return jsonb_build_object(
    'ok', true,
    'new_orders',       (select count(*) from public.orders where restaurant_id = v_id and status = 'new'),
    'active_orders',    (select count(*) from public.orders where restaurant_id = v_id
                           and status in ('accepted','preparing','ready')),
    'completed_orders', (select count(*) from public.orders where restaurant_id = v_id and status = 'completed'),
    'gifts_opened',     (select count(*) from public.daily_gifts where restaurant_id = v_id and opened_at >= since),
    'orders_from_gifts',(select count(*) from public.orders where restaurant_id = v_id
                           and gift_id is not null and created_at >= since),
    'gift_orders_completed', (select count(*) from public.orders where restaurant_id = v_id
                           and gift_id is not null and status = 'completed'),
    'revenue',          (select coalesce(sum(order_total),0) from public.orders
                           where restaurant_id = v_id and status = 'completed'),
    'fees_due',         (select coalesce(sum(platform_fee),0) from public.restaurant_ledger
                           where restaurant_id = v_id and billing_status = 'unbilled'),
    'menu_viewed',      (select count(*) from public.events where restaurant_id = v_id
                           and type = 'menu_view' and created_at >= since),
    'cart_created',     (select count(*) from public.events where restaurant_id = v_id
                           and type = 'cart_created' and created_at >= since),
    'days', coalesce(p_days,30)
  );
end $$;
$$;
end $$;
  select r.id, v_order, 'order_new', 'لديك طلب جديد',
         'طلب ' || v_code || ' — ' || v_total || ' ر.س'
   from public.restaurant_staff rs where rs.restaurant_id = r.id;

  insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)
create or replace function public.restaurant_orders(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid;
begin
  select restaurant_id into v_id from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  return jsonb_build_object('ok', true, 'orders', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'order_type', o.order_type,
      'total', o.order_total, 'discount', o.discount_amount, 'subtotal', o.subtotal,
      'customer_name', o.customer_name, 'customer_phone', o.customer_phone,
      'address', o.address, 'pickup_slot', o.pickup_slot, 'note', o.note,
      'created_at', o.created_at, 'has_discount', (o.gift_id is not null),
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'name', name_snapshot, 'qty', qty, 'line_total', line_total)), '[]'::jsonb)
                 from public.order_items i where i.order_id = o.id)
    ) order by o.created_at desc), '[]'::jsonb)
    from public.orders o
    where o.restaurant_id = v_id and (p_status is null or o.status::text = p_status)));
end $$;

create or replace function public.restaurant_statement(p_period text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_per text := coalesce(p_period, to_char(public.now_riyadh(),'YYYY-MM'));
begin
  select restaurant_id into v_id from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  return jsonb_build_object(
    'ok', true, 'period', v_per,
    'summary', (select jsonb_build_object(
        'completed_orders', completed_orders, 'total_order_value', total_order_value,
        'total_discounts', total_discounts, 'total_platform_fees', total_platform_fees,
        'outstanding', outstanding, 'status', status)
      from public.monthly_statements where restaurant_id = v_id and statement_period = v_per),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'order_id', l.order_id, 'code', o.code, 'order_total', l.order_total,
        'discount_amount', l.discount_amount, 'platform_fee', l.platform_fee,
        'restaurant_net', l.restaurant_net, 'completed_at', l.completed_at,
        'billing_status', l.billing_status) order by l.completed_at desc), '[]'::jsonb)
-- ============================================================
-- 9) إدارة المطعم: منيو + أوقات + ملف
-- ============================================================
create or replace function public.upsert_menu_item(
  p_id uuid default null, p_category uuid, p_name text, p_price numeric,
  p_description text default null, p_image text default null,
  p_available boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rest uuid;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  if p_id is null then
    insert into public.menu_items (restaurant_id, category_id, name, description, price, image_url, is_available)
    values (v_rest, p_category, p_name, p_description, p_price, p_image, p_available)
    returning id into v_id;
  else
    if not exists (select 1 from public.menu_items where id = p_id and restaurant_id = v_rest) then
      return jsonb_build_object('ok', false, 'error', 'forbidden');
    end if;
    update public.menu_items set category_id = p_category, name = p_name, description = p_description,
      price = p_price, image_url = p_image, is_available = p_available where id = p_id;
    v_id := p_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.upsert_category(p_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rest uuid;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  if p_id is null then
    insert into public.menu_categories (restaurant_id, name) values (v_rest, p_name) returning id into v_id;
  else
    update public.menu_categories set name = p_name where id = p_id and restaurant_id = v_rest;
    v_id := p_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.set_pickup_slots(p_slots text[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid; s text;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  update public.pickup_slots set is_active = false where restaurant_id = v_rest;
  foreach s in array coalesce(p_slots, '{}'::text[]) loop
    insert into public.pickup_slots (restaurant_id, slot_time) values (v_rest, s::time)
    on conflict (restaurant_id, slot_time) do update set is_active = true;
  end loop;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_restaurant_profile(
  p_name text default null, p_phone text default null, p_address text default null,
  p_area int default null, p_description text default null, p_logo text default null,
  p_cover text default null, p_pickup boolean default null, p_delivery boolean default null,
  p_prep int default null, p_hours jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;
  update public.restaurants set
    name = coalesce(p_name, name), phone = coalesce(p_phone, phone),
-- ============================================================
-- 10) Admin: الإعدادات والمطاعم والعروض
-- ============================================================
create or replace function public.admin_set_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  insert into public.app_settings (key, value, updated_by, updated_at)
  values (p_key, p_value, auth.uid(), now())
  on conflict (key) do update set value = excluded.value,
    updated_by = auth.uid(), updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_restaurants()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return jsonb_build_object('ok', true, 'restaurants', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'name', r.name, 'phone', r.phone, 'address', r.address,
      'area', a.name, 'status', r.status, 'pickup_enabled', r.pickup_enabled,
      'delivery_enabled', r.delivery_enabled, 'prep_time_min', r.prep_time_min,
      'created_at', r.created_at,
      'offers', (select count(*) from public.offers o where o.restaurant_id = r.id),
      'active_offers', (select count(*) from public.offers o
                         where o.restaurant_id = r.id and o.is_enabled),
      'orders', (select count(*) from public.orders o where o.restaurant_id = r.id),
      'completed', (select count(*) from public.orders o
                     where o.restaurant_id = r.id and o.status = 'completed'),
      'fees', (select coalesce(sum(platform_fee),0) from public.restaurant_ledger l
                 where l.restaurant_id = r.id)
    ) order by r.created_at desc), '[]'::jsonb)
    from public.restaurants r left join public.areas a on a.id = r.area_id));
end $$;

create or replace function public.admin_set_restaurant(p_id uuid, p_status public.restaurant_status)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  update public.restaurants set status = p_status where id = p_id;
create or replace function public.admin_all_offers()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return jsonb_build_object('ok', true, 'offers', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'restaurant', r.name, 'restaurant_id', r.restaurant_id,
      'title', o.title, 'min_discount', o.min_discount, 'max_discount', o.max_discount,
      'daily_limit', o.daily_limit, 'redeemed_today',
        case when o.redeemed_on = public.today_riyadh() then o.redeemed_today else 0 end,
      'is_enabled', o.is_enabled, 'active_from', o.active_from, 'active_until', o.active_until
    ) order by r.name), '[]'::jsonb)
    from public.offers o join public.restaurants r on r.id = o.restaurant_id));
end $$;

create or replace function public.admin_orders(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return jsonb_build_object('ok', true, 'orders', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'restaurant', r.name,
      'order_type', o.order_type, 'total', o.order_total, 'discount', o.discount_amount,
      'platform_fee', o.platform_fee, 'created_at', o.created_at,
      'completed_at', o.completed_at) order by o.created_at desc limit 200), '[]'::jsonb)
    from public.orders o join public.restaurants r on r.id = o.restaurant_id
    where p_status is null or o.status::text = p_status));
end $$;

create or replace function public.admin_ledger(p_period text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return jsonb_build_object(
    'ok', true,
    'totals', (select jsonb_build_object(
        'completed_orders', count(*), 'order_value', coalesce(sum(order_total),0),
        'discounts', coalesce(sum(discount_amount),0),
        'platform_fees', coalesce(sum(platform_fee),0))
      from public.restaurant_ledger l
      where p_period is null or l.statement_period = p_period),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'restaurant', r.name, 'code', o.code, 'order_total', l.order_total,
        'discount_amount', l.discount_amount, 'platform_fee', l.platform_fee,
        'restaurant_net', l.restaurant_net, 'period', l.statement_period,
        'billing_status', l.billing_status, 'completed_at', l.completed_at)
      order by l.completed_at desc limit 300), '[]'::jsonb)
      from public.restaurant_ledger l
      join public.restaurants r on r.id = l.restaurant_id
      join public.orders o on o.id = l.order_id
      where p_period is null or l.statement_period = p_period));
end $$;

create or replace function public.admin_close_period(p_period text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
-- ============================================================
-- 11) Admin KPIs — بدون أي benchmark مخترع
-- ============================================================
create or replace function public.admin_kpis(p_days int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - (coalesce(p_days,30) || ' days')::interval;
  d int := coalesce(p_days,30);
  e bigint; c bigint; m bigint; ct bigint; a bigint;
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;

  select count(*) into e from public.events where type = 'gift_open'   and created_at >= since;
  select count(*) into m from public.events where type = 'menu_view'   and created_at >= since;
  select count(*) into ct from public.events where type = 'cart_created' and created_at >= since;
  select count(*) into a from public.events where type = 'order_created' and created_at >= since;
  select count(*) into c from public.events where type = 'order_completed' and created_at >= since;

  return jsonb_build_object(
    'ok', true, 'days', d,
    'north_star', jsonb_build_object(
      'label', 'Completed Orders Generated Per Gift',
      'value', case when e = 0 then 0 else round(c::numeric / e, 4) end,
      'gifts_opened', e, 'completed_orders', c),
    'funnel', jsonb_build_object(
      'gift_open', e, 'menu_view', m, 'cart_created', ct,
      'order_created', a, 'order_completed', c,
      'gift_to_menu', case when e = 0 then 0 else round(m::numeric/e,4) end,
      'menu_to_cart', case when m = 0 then 0 else round(ct::numeric/m,4) end,
      'cart_to_order', case when ct = 0 then 0 else round(a::numeric/ct,4) end,
      'order_to_completed', case when a = 0 then 0 else round(c::numeric/a,4) end),
    'customer', jsonb_build_object(
      'dau', (select count(distinct device_id) from public.events
               where created_at >= now() - interval '1 day'),
      'devices_total', (select count(distinct device_id) from public.events
                         where created_at >= since),
      'devices_ordered', (select count(distinct device_id) from public.orders
                           where created_at >= since)),
    'restaurant', jsonb_build_object(
      'active', (select count(*) from public.restaurants where status = 'active'),
      'pending', (select count(*) from public.restaurants where status = 'pending'),
      'creating_offers', (select count(distinct restaurant_id) from public.offers
                           where created_at >= since),
      'receiving_orders', (select count(distinct restaurant_id) from public.orders
                            where created_at >= since),
      'returning', (select count(*) from (
          select restaurant_id from public.orders
           where status = 'completed' and created_at >= since
           group by restaurant_id having count(*) > 1) t)),
    'economics', jsonb_build_object(
      'completed_orders', c,
      'avg_platform_fee', (select coalesce(round(avg(platform_fee),2),0)
                            from public.orders where status = 'completed' and created_at >= since),
      'revenue', (select coalesce(sum(platform_fee),0) from public.orders
                   where status = 'completed' and created_at >= since),
      'revenue_per_completed_order', case when c = 0 then 0
        else round((select coalesce(sum(platform_fee),0) from public.orders
                    where status = 'completed' and created_at >= since)::numeric / c, 2) end)
  );
end $$;
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  update public.monthly_statements set status = 'closed' where statement_period = p_period;
-- ============================================================
-- 12) الصلاحيات
-- ============================================================
grant execute on function public.cfg(text) to anon, authenticated;
grant execute on function public.open_daily_gift(uuid, int) to anon, authenticated;
grant execute on function public.save_consent(uuid, uuid, public.consent_type, public.consent_status) to anon, authenticated;
grant execute on function public.log_event(text, uuid, uuid, uuid, uuid, jsonb) to anon, authenticated;
grant execute on function public.create_order(uuid, uuid, public.order_type, jsonb, text, text, int, text, time, text, boolean, boolean) to anon, authenticated;
grant execute on function public.customer_order(uuid, text) to anon, authenticated;
grant execute on function public.customer_orders(uuid) to anon, authenticated;
grant execute on function public.customer_notifications(uuid) to anon, authenticated;
grant execute on function public.customer_consents(uuid) to anon, authenticated;
grant execute on function public.active_areas() to anon, authenticated;
grant execute on function public.restaurant_menu(uuid) to anon, authenticated;
grant execute on function public.transition_order(uuid, public.order_status, text) to authenticated;
grant execute on function public.register_restaurant(text, text, text, int, text, boolean, boolean) to authenticated;
grant execute on function public.restaurant_dashboard(int) to authenticated;
grant execute on function public.restaurant_orders(text) to authenticated;
grant execute on function public.restaurant_statement(text) to authenticated;
grant execute on function public.upsert_menu_item(uuid, uuid, text, numeric, text, text, boolean) to authenticated;
grant execute on function public.upsert_category(uuid, text) to authenticated;
grant execute on function public.set_pickup_slots(text[]) to authenticated;
grant execute on function public.update_restaurant_profile(text, text, text, int, text, text, text, boolean, boolean, int, jsonb) to authenticated;
grant execute on function public.admin_set_setting(text, jsonb) to authenticated;
grant execute on function public.admin_list_restaurants() to authenticated;
grant execute on function public.admin_set_restaurant(uuid, public.restaurant_status) to authenticated;
grant execute on function public.admin_set_offer(uuid, boolean) to authenticated;
grant execute on function public.admin_all_offers() to authenticated;
grant execute on function public.admin_orders(text) to authenticated;
grant execute on function public.admin_ledger(text) to authenticated;
grant execute on function public.admin_close_period(text) to authenticated;
grant execute on function public.admin_kpis(int) to authenticated;

revoke all on public.orders                 from anon;
revoke all on public.order_items            from anon;
revoke all on public.daily_gifts             from anon;
revoke all on public.gift_redemptions       from anon;
revoke all on public.offers                  from anon;
revoke all on public.events                  from anon;
revoke all on public.consents                from anon;
revoke all on public.notifications           from anon;
revoke all on public.restaurant_ledger      from anon;
revoke all on public.monthly_statements     from anon;
revoke all on public.admin_users            from anon;
revoke all on public.restaurant_staff       from anon;
  update public.restaurant_ledger set billing_status = 'billed'
   where statement_period = p_period and billing_status = 'unbilled';
  return jsonb_build_object('ok', true, 'period', p_period);
end $$;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_offer(p_id uuid, p_enabled boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  update public.offers set is_enabled = p_enabled where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
    address = coalesce(p_address, address), area_id = coalesce(p_area, area_id),
    description = coalesce(p_description, description), logo_url = coalesce(p_logo, logo_url),
    cover_url = coalesce(p_cover, cover_url),
    pickup_enabled = coalesce(p_pickup, pickup_enabled),
    delivery_enabled = coalesce(p_delivery, delivery_enabled),
    prep_time_min = coalesce(p_prep, prep_time_min),
    opening_hours = coalesce(p_hours, opening_hours)
   where id = v_rest;
  return jsonb_build_object('ok', true);
end $$;
      from public.restaurant_ledger l join public.orders o on o.id = l.order_id
      where l.restaurant_id = v_id and l.statement_period = v_per),
    'periods', (select coalesce(jsonb_agg(statement_period order by statement_period desc), '[]'::jsonb)
      from (select statement_period from public.monthly_statements
             where restaurant_id = v_id) s));
end $$;
  values (p_device, r.id, 'order_contact', 'granted',
          coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));

  if p_consent_marketing then
    insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)
    values (p_device, r.id, 'marketing', 'granted',
            coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'code', v_code,
                            'subtotal', v_sub, 'discount', v_disc, 'total', v_total);
end $$;

  insert into public.events (device_id, gift_id, restaurant_id, type)
  values (p_device, new_gift, picked.restaurant_id, 'gift_open');

  return public.gift_payload(new_gift);
exception when unique_violation then
  select id into new_gift from public.daily_gifts
   where device_id = p_device and gift_date = v_today;
  return public.gift_payload(new_gift);
end $$;
    'offer', jsonb_build_object('title', o.title, 'description', o.description,
                                'expires_at', o.active_until)
  );
end $$;
end $$;
