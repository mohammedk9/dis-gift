-- ============================================================
-- هدية | Lean MVP — 0008_delivery.sql
-- التوصيل برسوم يحددها كل منشأة بنفسها — والسيرفر هو من يحسبها
-- ============================================================
-- قواعد ثابتة في هذا الإصدار:
--  1) مصدر رسوم التوصيل هو صف المنشأة (restaurants.delivery_fee).
--     create_order لا يستقبل أي مبلغ من المتصفح — لا وسيط للرسوم في توقيعه.
--  2) order_total = subtotal − discount + delivery_fee
--  3) رسوم المنصة تبقى ثابتة على الطلب المكتمل فقط،
--     ولا تُحسب على رسوم التوصيل: الأساس = order_total − delivery_fee.
--  4) restaurant_net = order_total − platform_fee
--     إصلاح: النسخة السابقة في 0003 كانت تخصم الخصم مرّتين
--     (order_total − discount − fee) بعد أن كان order_total يتضمن الخصم أصلاً.
--  5) الطلب لا يُقبل من المنشأة قبل تأكيد العميل للسعر متى ما أُضيفت
--     رسوم توصيل. وأي تغيير في السعر يُلغي التأكيد السابق.
-- ============================================================

-- ---------- 0) إعدادات: الحد الأعلى لرسوم التوصيل ----------
-- ASSUMPTION: لا توجد قيمة رسوم توصيل مُحددة في المتطلبات. 25 ر.س حداً أعلى
--    مؤقتاً حتى يقرره الأدمن من لوحة الإعدادات. حذف الإعداد ⇒ الحد صفر
--    (اتجاه آمن: لا رسوم توصيل على أي طلب).
insert into public.app_settings (key, value, description) values
 ('delivery_fee_max', '25'::jsonb,
  'الحد الأعلى لرسوم التوصيل التي تستطيع أي منشأة تحديدها (ر.س). حذف الإعداد يصفّره.')
on conflict (key) do nothing;

-- ---------- 1) أعمدة التوصيل ----------
alter table public.restaurants add column if not exists delivery_fee numeric(10,2) not null default 0;
alter table public.orders      add column if not exists delivery_fee numeric(10,2) not null default 0;
alter table public.orders      add column if not exists price_confirmed_at timestamptz;
alter table public.orders      add column if not exists price_confirmed_total numeric(10,2);
alter table public.restaurant_ledger add column if not exists delivery_fee numeric(10,2) not null default 0;

do $$ begin
  alter table public.restaurants add constraint restaurants_delivery_fee_nonneg
    check (delivery_fee >= 0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.orders add constraint orders_delivery_fee_nonneg
    check (delivery_fee >= 0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.restaurant_ledger add constraint ledger_delivery_fee_nonneg
    check (delivery_fee >= 0);
exception when duplicate_object then null; end $$;

-- ملاحظة عن البيانات القائمة: أي منشأة فعّلت التوصيل سابقاً تبدأ برسوم صفر
-- (توصيل مجاني) حتى تحدد رسومها بنفسها. لا قيمة مخترعة نيابة عنها.
--
-- والطلبات القائمة قبل هذه الهجرة تُعتبر مؤكدة السعر (delivery_fee = 0 لها،
-- فلا يوجد عنصر سعر جديد يقبله العميل) حتى لا يتعطّل أي طلب جارٍ في لوحة المنشأة.
-- التعبئة تعمل **مرة واحدة** فقط (علامة في app_settings): إعادة تشغيل الملف
-- لاحقاً لا تُؤكّد طلبات جديدة كانت بانتظار تأكيد العميل.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'delivery_backfill_at') then
    update public.orders
       set price_confirmed_at = coalesce(price_confirmed_at, created_at),
           price_confirmed_total = coalesce(price_confirmed_total, order_total)
     where price_confirmed_at is null;
    insert into public.app_settings (key, value, description)
    values ('delivery_backfill_at', to_jsonb(now()),
            'وقت تعبئة تأكيد السعر للطلبات السابقة على 0008_delivery — يمنع تكرار التعبئة.');
  end if;
end $$;

-- ---------- 2) الحد الأعلى + رسوم المنشأة (السيرفر هو المرجع) ----------
create or replace function public.delivery_fee_cap() returns numeric
language sql stable set search_path = public as $$
  select greatest(coalesce((public.cfg('delivery_fee_max') #>> '{}')::numeric, 0), 0);
$$;

-- حارس على جدول المنشآت: يعمل على أي مسار كتابة (RPC أو تحديث مباشر
-- من صاحب المنشأة عبر RLS)، فلا يمكن تجاوز الحد الأعلى ولا كتابة قيمة سالبة.
create or replace function public.guard_delivery_fee() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.delivery_fee is null or new.delivery_fee < 0 then
    new.delivery_fee := 0;
  end if;
  if new.delivery_fee > public.delivery_fee_cap() then
    new.delivery_fee := public.delivery_fee_cap();
  end if;
  return new;
end $$;

drop trigger if exists trg_restaurants_delivery_fee on public.restaurants;
create trigger trg_restaurants_delivery_fee before insert or update on public.restaurants
  for each row execute function public.guard_delivery_fee();

-- رسوم التوصيل الفعلية لمنشأة: صفر إذا كانت لا توفر التوصيل أو أوقفته.
-- دالة داخلية: لا تُنشر عبر الـ API (revoke في نهاية الملف).
create or replace function public.delivery_fee_for(p_restaurant uuid)
returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when r.id is null or not r.delivery_enabled then 0
    else round(least(greatest(coalesce(r.delivery_fee, 0), 0), public.delivery_fee_cap()), 2)
  end
  from (select 1) as x
  left join public.restaurants r on r.id = p_restaurant;
$$;

-- ============================================================
-- 3) إنشاء طلب من هدية — نفس التوقيع، ورسوم التوصيل من السيرفر
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
  v_sub numeric := 0; v_disc numeric := 0; v_fee numeric := 0; v_total numeric := 0;
  v_code text; v_order uuid; v_confirm boolean := false;
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
  -- التوصيل يحتاج عنواناً مكتوباً؛ الرسوم نفسها تُحسب على السيرفر لا من المتصفح
  if p_type = 'delivery' and coalesce(trim(p_address), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'address_required');
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

  v_disc  := case g.gift_kind
               when 'percent' then least(v_sub * g.discount_value / 100, v_sub)
               when 'fixed_amount' then least(g.discount_value, v_sub)
               else 0   -- free_item: يُطبَّق الصنف المجاني على السلة أدناه
             end;
  -- رسوم التوصيل: من صف المنشأة فقط، ومحصورة بالحد الأعلى للإدارة
  v_fee   := case when p_type = 'delivery' then public.delivery_fee_for(r.id) else 0 end;
  v_total := round(v_sub - v_disc + v_fee, 2);
  -- لا نطلب تأكيداً إلا إذا أُضيف عنصر سعر جديد لم يره العميل قبل الطلب
  v_confirm := v_fee > 0;
  v_code  := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

  insert into public.orders
    (code, restaurant_id, device_id, gift_id, order_type, status,
     subtotal, discount_amount, delivery_fee, order_total, platform_fee,
     customer_name, customer_phone, area_id, address, pickup_slot, note,
     price_confirmed_at, price_confirmed_total)
  values
    (v_code, r.id, p_device, g.id, p_type, 'new',
     v_sub, v_disc, v_fee, v_total, 0,
     p_name, p_phone, p_area, p_address, p_slot, p_note,
     case when v_confirm then null else now() end,
     case when v_confirm then null else v_total end)
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

  -- صنف مجاني: يُضاف للطلب تلقائياً بسعر صفر إن لم يطلبه العميل أصلاً
  if g.gift_kind = 'free_item' and g.gift_item_id is not null then
    select * into it from public.menu_items
     where id = g.gift_item_id and restaurant_id = r.id and is_available;
    if found then
      insert into public.order_items
        (order_id, menu_item_id, name_snapshot, price_snapshot, qty, line_total, note)
      values (v_order, it.id, it.name, it.price, 1, 0, 'هدية اليوم');
      -- الزيادة في subtotal تقابلها زيادة في discount ⇒ الإجمالي لا يتغير
      update public.orders
         set subtotal = round(subtotal + it.price, 2),
             discount_amount = round(discount_amount + it.price, 2),
             order_total = round(order_total, 2)
       where id = v_order;
      v_disc := round(v_disc + it.price, 2);
      v_sub  := round(v_sub + it.price, 2);
    end if;
  end if;

  insert into public.gift_redemptions
    (gift_id, order_id, device_id, restaurant_id, gift_kind, discount_value)
  values (g.id, v_order, p_device, r.id, g.gift_kind, v_disc);
  update public.daily_gifts set status = 'redeemed' where id = g.id;
  update public.offers set redeemed_today = case when redeemed_on = public.today_riyadh()
      then redeemed_today + 1 else 1 end,
      redeemed_on = public.today_riyadh()
   where id = g.offer_id;

  insert into public.order_events (order_id, to_status, actor_role)
  values (v_order, 'new', 'customer');

  insert into public.events (device_id, restaurant_id, gift_id, order_id, type, meta)
  values (p_device, r.id, g.id, v_order, 'order_created',
          jsonb_build_object('total', v_total, 'order_type', p_type, 'delivery_fee', v_fee));

  insert into public.notifications (restaurant_id, order_id, type, title, body)
  select r.id, v_order, 'order_new', 'لديك طلب جديد',
         'طلب ' || v_code || ' — ' || v_total || ' ر.س'
    from public.restaurant_staff rs where rs.restaurant_id = r.id;

  insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)
  values (p_device, r.id, 'order_contact', 'granted',
          coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));

  if p_consent_marketing then
    insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)
    values (p_device, r.id, 'marketing', 'granted',
            coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'code', v_code,
                            'order_type', p_type,
                            'subtotal', v_sub, 'discount', v_disc,
                            'delivery_fee', v_fee, 'total', v_total,
                            'awaiting_price_confirmation', v_confirm);
end $$;

-- ============================================================
-- 4) دورة حالة الطلب — الرسوم فقط عند COMPLETED
--    new → accepted → preparing → ready → completed
--    أي حالة أخرى → cancelled | no_show  (بلا رسوم)
--    ولا يُقبل الطلب قبل تأكيد العميل للسعر (يشمل رسوم التوصيل).
-- ============================================================
create or replace function public.transition_order(
  p_order uuid, p_to public.order_status, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ord record; frm public.order_status; actor public.app_role;
  v_fee numeric; v_period text; v_net numeric; v_base numeric;
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

  -- السعر لم يُؤكَّد من العميل بعد ⇒ لا قبول (رسوم التوصيل تُقرأ قبل الموافقة)
  if p_to = 'accepted' and ord.price_confirmed_at is null then
    return jsonb_build_object('ok', false, 'error', 'price_not_confirmed',
                              'delivery_fee', ord.delivery_fee, 'total', ord.order_total);
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
    -- الأساس: قيمة الطلب بلا رسوم التوصيل ⇒ رسوم المنصة لا تُحسب على التوصيل
    v_base := greatest(round(ord.order_total - ord.delivery_fee, 2), 0);
    v_fee := coalesce((public.cfg('platform_fee') #>> '{}')::numeric, 0);
    v_fee := greatest(least(v_fee, v_base), 0);   -- لا رسوم أكبر من قيمة الطلب بلا توصيل
    v_net  := round(ord.order_total - v_fee, 2);  -- رسوم التوصيل تُحصَّل للمنشأة كاملة
    v_period := to_char(public.now_riyadh(), 'YYYY-MM');

    update public.orders set platform_fee = v_fee where id = p_order;

    insert into public.restaurant_ledger
      (restaurant_id, order_id, order_total, discount_amount, delivery_fee, platform_fee,
       restaurant_net, statement_period)
    values (ord.restaurant_id, p_order, ord.order_total, ord.discount_amount,
            ord.delivery_fee, v_fee, v_net, v_period)
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
            jsonb_build_object('total', ord.order_total, 'fee', v_fee,
                               'delivery_fee', ord.delivery_fee));
  end if;

  return jsonb_build_object('ok', true, 'status', p_to, 'platform_fee',
                            case when p_to = 'completed' then v_fee else 0 end);
end $$;

-- ============================================================
-- 5) تغيير طريقة الاستلام قبل القبول (العميل فقط، وجهازه فقط)
--    التغيير يُعيد حساب رسوم التوصيل ويُلغي أي تأكيد سعر سابق.
-- ============================================================
create or replace function public.set_order_delivery(
  p_device uuid, p_code text, p_type public.order_type,
  p_address text default null, p_slot time default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; r record; v_addr text; v_fee numeric; v_total numeric; v_confirm boolean;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  -- التغيير مسموح فقط قبل أن تبدأ المنشأة التنفيذ
  if o.status <> 'new' then
    return jsonb_build_object('ok', false, 'error', 'invalid_delivery_change', 'status', o.status);
  end if;

  select * into r from public.restaurants where id = o.restaurant_id;
  if r.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'restaurant_unavailable');
  end if;

  if p_type = 'delivery' then
    if not r.delivery_enabled then
      return jsonb_build_object('ok', false, 'error', 'delivery_not_available');
    end if;
    v_addr := nullif(trim(coalesce(p_address, o.address, '')), '');
    if v_addr is null then
      return jsonb_build_object('ok', false, 'error', 'address_required');
    end if;
  else
    if not r.pickup_enabled then
      return jsonb_build_object('ok', false, 'error', 'pickup_not_available');
    end if;
    if coalesce(p_slot, o.pickup_slot) is null then
      return jsonb_build_object('ok', false, 'error', 'pickup_slot_required');
    end if;
    v_addr := o.address;
  end if;

  v_fee   := case when p_type = 'delivery' then public.delivery_fee_for(o.restaurant_id) else 0 end;
  v_total := round(o.subtotal - o.discount_amount + v_fee, 2);
  v_confirm := v_fee > 0;   -- السعر تغيّر ⇒ يحتاج تأكيداً جديداً من العميل

  update public.orders set
    order_type = p_type,
    delivery_fee = v_fee,
    order_total = v_total,
    address = v_addr,
    pickup_slot = case when p_type = 'pickup' then coalesce(p_slot, o.pickup_slot)
                       else null end,   -- التوصيل بلا وقت استلام (لا يبقى وقت قديم)
    price_confirmed_at = case when v_confirm then null else now() end,
    price_confirmed_total = case when v_confirm then null else v_total end
   where id = o.id;

  insert into public.order_events (order_id, from_status, to_status, actor_role, note)
  values (o.id, o.status, o.status, 'customer',
          case when p_type = 'delivery' then 'العميل حوّل الطلب إلى توصيل'
               else 'العميل حوّل الطلب إلى استلام' end);

  return jsonb_build_object('ok', true, 'order_type', p_type, 'delivery_fee', v_fee,
                            'total', v_total, 'awaiting_price_confirmation', v_confirm);
end $$;

-- ============================================================
-- 6) تأكيد العميل للسعر (يشمل رسوم التوصيل)
--    العميل يؤكد رقماً محدداً رآه: إن تغيّر السعر بين العرض والتأكيد يُرفض.
-- ============================================================
create or replace function public.customer_confirm_order_price(
  p_device uuid, p_code text, p_expected_total numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  if o.status <> 'new' then
    return jsonb_build_object('ok', false, 'error', 'invalid_transition', 'status', o.status);
  end if;

  if p_expected_total is not null and round(p_expected_total, 2) <> round(o.order_total, 2) then
    return jsonb_build_object('ok', false, 'error', 'price_changed',
                              'subtotal', o.subtotal, 'discount', o.discount_amount,
                              'delivery_fee', o.delivery_fee, 'total', o.order_total);
  end if;

  -- أول تأكيد يُحفظ بوقته وقيمته (إعادة التأكيد لا تُغيّر السجل)
  update public.orders
     set price_confirmed_at = coalesce(price_confirmed_at, now()),
         price_confirmed_total = coalesce(price_confirmed_total, order_total)
   where id = o.id;

  return jsonb_build_object('ok', true, 'code', o.code,
                            'subtotal', o.subtotal, 'discount', o.discount_amount,
                            'delivery_fee', o.delivery_fee, 'total', o.order_total,
                            'awaiting_price_confirmation', false);
end $$;

-- ============================================================
-- 7) رسوم التوصيل: صاحب المنشأة يحددها بنفسه
--    التحقق على السيرفر: صيغة صحيحة + داخل الحد الأعلى للإدارة.
-- ============================================================
create or replace function public.set_restaurant_delivery_fee(p_fee numeric)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid; v_cap numeric; v_txt text;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  -- الصيغة الصحيحة: رقم غير سالب بمنزلتين عشريتين على الأكثر
  if p_fee is null then return jsonb_build_object('ok', false, 'error', 'delivery_fee_invalid'); end if;
  v_txt := p_fee::text;
  if v_txt !~ '^[0-9]+(\.[0-9]{1,2})?$' then
    return jsonb_build_object('ok', false, 'error', 'delivery_fee_invalid');
  end if;

  v_cap := public.delivery_fee_cap();
  if p_fee > v_cap then
    return jsonb_build_object('ok', false, 'error', 'delivery_fee_cap', 'cap', v_cap);
  end if;

  update public.restaurants set delivery_fee = round(p_fee, 2) where id = v_rest;
  return jsonb_build_object('ok', true, 'delivery_fee', round(p_fee, 2), 'cap', v_cap);
end $$;

-- ============================================================
-- 8) توسيع حمولات القراءة: رسوم التوصيل + حالة تأكيد السعر
--    نفس التوقيع ونفس النوع — استبدال آمن (create or replace).
-- ============================================================
create or replace function public.gift_payload(p_gift uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g record; r record; o record;
begin
  select * into g from public.daily_gifts where id = p_gift;
  if not found then return jsonb_build_object('ok', false, 'error', 'gift_not_found'); end if;

  select id, name, description, logo_url, cover_url, phone, address,
         pickup_enabled, delivery_enabled, prep_time_min, area_id, city, business_type,
         whatsapp, whatsapp_orders_enabled, delivery_fee
    into r from public.restaurants where id = g.restaurant_id;
  select title, description, active_until into o from public.offers where id = g.offer_id;

  return jsonb_build_object(
    'ok', true,
    'gift', jsonb_build_object(
      'id', g.id,
      'code', g.code,
      'kind', g.gift_kind,
      'discount', g.discount_value,
      'gift_item_id', g.gift_item_id,
      'gift_label', g.gift_label,
      'status', g.status,
      'opened_at', g.opened_at,
      'redeemed', (g.status = 'redeemed')
    ),
    'restaurant', jsonb_build_object(
      'id', r.id, 'name', r.name, 'description', r.description,
      'logo_url', r.logo_url, 'cover_url', r.cover_url,
      'phone', r.phone, 'address', r.address, 'city', r.city,
      'business_type', r.business_type,
      'pickup_enabled', r.pickup_enabled, 'delivery_enabled', r.delivery_enabled,
      'delivery_fee', case when r.delivery_enabled then public.delivery_fee_for(r.id) else 0 end,
      'prep_time_min', r.prep_time_min,
      'whatsapp', r.whatsapp,
      'whatsapp_orders_enabled', r.whatsapp_orders_enabled
    ),
    'offer', jsonb_build_object(
      'title', o.title, 'description', o.description, 'expires_at', o.active_until
    )
  );
end $$;

create or replace function public.restaurant_menu(p_restaurant uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'restaurant', (select jsonb_build_object('id', id, 'name', name, 'description', description,
        'logo_url', logo_url, 'cover_url', cover_url, 'phone', phone, 'address', address,
        'business_type', business_type,
        'pickup_enabled', pickup_enabled, 'delivery_enabled', delivery_enabled,
        'delivery_fee', case when delivery_enabled
                        then public.delivery_fee_for(id) else 0 end,
        'prep_time_min', prep_time_min, 'min_order_total', min_order_total,
        'whatsapp', whatsapp, 'whatsapp_orders_enabled', whatsapp_orders_enabled)
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
$$;

-- ---------- 9) نص الفاتورة: سطر رسوم التوصيل ----------
-- المتصفح يبني رابط wa.me فقط، ولا يحسب أي رقم أو كود بنفسه.
create or replace function public.order_invoice_text(p_order uuid, p_title text default 'فاتورة طلب')
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  o record; r record; g record; it record;
  v_lines text := '';
  v_out   text := '';
begin
  select * into o from public.orders where id = p_order;
  if not found then return null; end if;

  select name, phone, whatsapp, whatsapp_orders_enabled
    into r from public.restaurants where id = o.restaurant_id;

  for it in select name_snapshot, qty, line_total from public.order_items
             where order_id = p_order order by name_snapshot loop
    v_lines := v_lines || '• ' || it.qty || ' × ' || it.name_snapshot || ' — ' ||
               round(it.line_total, 2)::text || ' ر.س' || E'\n';
  end loop;

  v_out := p_title || E'\n' ||
           r.name || E'\n' ||
           'رقم الطلب: ' || o.code || E'\n' ||
           to_char(o.created_at at time zone 'Asia/Riyadh', 'YYYY-MM-DD HH24:MI') || E'\n' ||
           '—————' || E'\n' || v_lines || '—————' || E'\n' ||
           'الإجمالي: ' || round(o.subtotal, 2)::text || ' ر.س' || E'\n' ||
           'الخصم: -' || round(o.discount_amount, 2)::text || ' ر.س' || E'\n' ||
           case when o.delivery_fee > 0
                then 'رسوم التوصيل: ' || round(o.delivery_fee, 2)::text || ' ر.س' || E'\n'
                else '' end ||
           'المطلوب دفعه: ' || round(o.order_total, 2)::text || ' ر.س' || E'\n';

  if o.gift_id is not null then
    select code, gift_kind, discount_value, gift_label
      into g from public.daily_gifts where id = o.gift_id;
    v_out := v_out || 'كود الهدية: ' || coalesce(g.code, '-') || ' (' ||
      case g.gift_kind
        when 'percent' then 'خصم ' || to_char(g.discount_value, 'FM999990.99') || '%'
        when 'fixed_amount' then 'هدية ' || to_char(g.discount_value, 'FM999990.99') || ' ر.س'
        else coalesce(g.gift_label, 'صنف مجاني')
      end || ')' || E'\n';
  end if;

  v_out := v_out || '—————' || E'\n' ||
           'طريقة الاستلام: ' ||
           case o.order_type when 'pickup' then 'استلام من المنشأة' else 'توصيل من المنشأة' end || E'\n';

  if o.pickup_slot is not null then
    v_out := v_out || 'وقت الاستلام: ' || to_char(o.pickup_slot, 'HH24:MI') || E'\n';
  end if;

  v_out := v_out || 'الاسم: ' || o.customer_name || E'\n' ||
           'الجوال: ' || o.customer_phone || E'\n';

  if o.address is not null then v_out := v_out || 'العنوان: ' || o.address || E'\n'; end if;
  if o.note    is not null then v_out := v_out || 'ملاحظة: ' || o.note || E'\n'; end if;

  v_out := v_out || '—————' || E'\n' ||
           'الدفع يتم مباشرة مع المنشأة — لا دفع إلكتروني عبر المنصة.';
  return v_out;
end $$;

-- ---------- 10) قراءة الطلب للعميل: رسوم التوصيل + حالة تأكيد السعر ----------
create or replace function public.customer_order(p_device uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; r record;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;
  select name, phone, address, logo_url, whatsapp, whatsapp_orders_enabled, delivery_enabled
    into r from public.restaurants where id = o.restaurant_id;
  return jsonb_build_object(
    'ok', true,
    'order', jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'order_type', o.order_type,
      'subtotal', o.subtotal, 'discount', o.discount_amount,
      'delivery_fee', o.delivery_fee,
      'total', o.order_total,
      'awaiting_price_confirmation', (o.price_confirmed_at is null),
      'price_confirmed_at', o.price_confirmed_at,
      'price_confirmed_total', o.price_confirmed_total,
      'pickup_slot', o.pickup_slot, 'note', o.note, 'created_at', o.created_at,
      'completed_at', o.completed_at, 'customer_name', o.customer_name,
      'customer_phone', o.customer_phone, 'address', o.address,
      'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
      'gift_kind', (select dg.gift_kind from public.daily_gifts dg where dg.id = o.gift_id),
      'whatsapp_shared_at', o.whatsapp_shared_at,
      'payment_note', 'الدفع يتم مباشرة للمطعم.'
    ),
    'restaurant', jsonb_build_object('id', r.id, 'name', r.name, 'phone', r.phone,
                                     'address', r.address, 'logo_url', r.logo_url,
                                     'whatsapp', r.whatsapp,
                                     'delivery_enabled', r.delivery_enabled,
                                     'delivery_fee', public.delivery_fee_for(o.restaurant_id),
                                     'whatsapp_orders_enabled', r.whatsapp_orders_enabled),
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

-- ---------- 11) مشاركة العميل فاتورته مع المنشأة ----------
create or replace function public.customer_order_share(p_device uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; r record; v_text text;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  select name, whatsapp, whatsapp_orders_enabled
    into r from public.restaurants where id = o.restaurant_id;

  v_text := public.order_invoice_text(o.id, 'فاتورة طلب');

  -- يُسجَّل مرة واحدة: لحظة تسليم الفاتورة عبر واتساب (قناة توصيل، بلا رسوم).
  if r.whatsapp_orders_enabled and r.whatsapp is not null then
    update public.orders set whatsapp_shared_at = coalesce(whatsapp_shared_at, now())
     where id = o.id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', o.code,
    'restaurant', r.name,
    'whatsapp', r.whatsapp,
    'whatsapp_ready', (r.whatsapp_orders_enabled and r.whatsapp is not null),
    'invoice', v_text,
    'subtotal', o.subtotal,
    'discount', o.discount_amount,
    'delivery_fee', o.delivery_fee,
    'order_type', o.order_type,
    'awaiting_price_confirmation', (o.price_confirmed_at is null),
    'total', o.order_total,
    'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
    'whatsapp_shared_at', (select x.whatsapp_shared_at from public.orders x where x.id = o.id)
  );
end $$;

-- ---------- 12) طلبات المنشأة: رسوم التوصيل + انتظار تأكيد السعر ----------
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
      'delivery_fee', o.delivery_fee,
      'awaiting_price_confirmation', (o.price_confirmed_at is null),
      'price_confirmed_at', o.price_confirmed_at,
      'customer_name', o.customer_name, 'customer_phone', o.customer_phone,
      'address', o.address, 'pickup_slot', o.pickup_slot, 'note', o.note,
      'created_at', o.created_at, 'has_discount', (o.gift_id is not null),
      'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
      'gift_kind', (select dg.gift_kind from public.daily_gifts dg where dg.id = o.gift_id),
      'whatsapp_shared_at', o.whatsapp_shared_at,
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'name', name_snapshot, 'qty', qty, 'line_total', line_total)), '[]'::jsonb)
                 from public.order_items i where i.order_id = o.id)
    ) order by o.created_at desc), '[]'::jsonb)
    from public.orders o
    where o.restaurant_id = v_id and (p_status is null or o.status::text = p_status)));
end $$;



-- ============================================================
-- 13) لوحة المنشأة: أرقام التوصيل وتأكيد السعر
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
    'delivery_orders',  (select count(*) from public.orders where restaurant_id = v_id
                           and order_type = 'delivery' and created_at >= since),
    'delivery_fees_collected', (select coalesce(sum(delivery_fee),0) from public.orders
                           where restaurant_id = v_id and status = 'completed' and created_at >= since),
    'awaiting_price_confirmation', (select count(*) from public.orders where restaurant_id = v_id
                           and status = 'new' and price_confirmed_at is null),
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
    -- رسوم التوصيل تُحصَّل للمنشأة مباشرة (لا تدخل في فاتورة المنصة)
    'delivery_fees', (select coalesce(sum(delivery_fee),0) from public.restaurant_ledger
      where restaurant_id = v_id and statement_period = v_per),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
        'order_id', l.order_id, 'code', o.code, 'order_total', l.order_total,
        'discount_amount', l.discount_amount, 'delivery_fee', l.delivery_fee,
        'platform_fee', l.platform_fee,
        'restaurant_net', l.restaurant_net, 'completed_at', l.completed_at,
        'billing_status', l.billing_status) order by l.completed_at desc), '[]'::jsonb)
      from public.restaurant_ledger l join public.orders o on o.id = l.order_id
      where l.restaurant_id = v_id and l.statement_period = v_per),
    'periods', (select coalesce(jsonb_agg(statement_period order by statement_period desc), '[]'::jsonb)
      from (select statement_period from public.monthly_statements
             where restaurant_id = v_id) s));
end $$;


-- ============================================================
-- 14) Admin: قائمة المنشآت + المؤشرات
-- ============================================================
create or replace function public.admin_list_restaurants()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  return jsonb_build_object('ok', true, 'restaurants', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'name', r.name, 'phone', r.phone, 'address', r.address,
      'area', a.name, 'status', r.status, 'business_type', r.business_type,
      'pickup_enabled', r.pickup_enabled,
      'delivery_enabled', r.delivery_enabled, 'prep_time_min', r.prep_time_min,
      'delivery_fee', public.delivery_fee_for(r.id),
      'delivery_fee_raw', r.delivery_fee,
      'whatsapp', r.whatsapp,
      'whatsapp_orders_enabled', r.whatsapp_orders_enabled,
      'created_at', r.created_at,
      'offers', (select count(*) from public.offers o where o.restaurant_id = r.id),
      'active_offers', (select count(*) from public.offers o
                         where o.restaurant_id = r.id and o.is_enabled),
      'orders', (select count(*) from public.orders o where o.restaurant_id = r.id),
      'delivery_orders', (select count(*) from public.orders o
                           where o.restaurant_id = r.id and o.order_type = 'delivery'),
      'completed', (select count(*) from public.orders o
                     where o.restaurant_id = r.id and o.status = 'completed'),
      'delivery_fees_collected', (select coalesce(sum(delivery_fee),0) from public.restaurant_ledger l
                     where l.restaurant_id = r.id),
      'fees', (select coalesce(sum(platform_fee),0) from public.restaurant_ledger l
                 where l.restaurant_id = r.id)
    ) order by r.created_at desc), '[]'::jsonb)
    from public.restaurants r left join public.areas a on a.id = r.area_id));
end $$;

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

    -- التوصيل: رسومه لا تدخل في اقتصاد المنصة (تُحصَّل للمنشأة كاملة)
    'delivery', jsonb_build_object(
      'orders', (select count(*) from public.orders
                  where order_type = 'delivery' and created_at >= since),
      'completed', (select count(*) from public.orders
                     where order_type = 'delivery' and status = 'completed' and created_at >= since),
      'avg_fee', (select coalesce(round(avg(delivery_fee),2),0) from public.orders
                   where order_type = 'delivery' and created_at >= since),
      'fees_collected_by_merchants', (select coalesce(sum(delivery_fee),0) from public.orders
                   where order_type = 'delivery' and status = 'completed' and created_at >= since),
      'restaurants_offering', (select count(*) from public.restaurants where delivery_enabled),
      'awaiting_confirmation', (select count(*) from public.orders
                   where status = 'new' and price_confirmed_at is null)),

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

-- ============================================================
-- 15) الصلاحيات
-- ============================================================
grant execute on function public.create_order(uuid, uuid, public.order_type, jsonb, text, text, int, text, time, text, boolean, boolean) to anon, authenticated;
grant execute on function public.customer_order(uuid, text) to anon, authenticated;
grant execute on function public.customer_order_share(uuid, text) to anon, authenticated;
grant execute on function public.set_order_delivery(uuid, text, public.order_type, text, time) to anon, authenticated;
grant execute on function public.customer_confirm_order_price(uuid, text, numeric) to anon, authenticated;
grant execute on function public.restaurant_menu(uuid) to anon, authenticated;
grant execute on function public.set_restaurant_delivery_fee(numeric) to authenticated;
grant execute on function public.transition_order(uuid, public.order_status, text) to authenticated;
grant execute on function public.restaurant_dashboard(int) to authenticated;
grant execute on function public.restaurant_orders(text) to authenticated;
grant execute on function public.restaurant_statement(text) to authenticated;
grant execute on function public.admin_list_restaurants() to authenticated;
grant execute on function public.admin_kpis(int) to authenticated;

-- ملاحظة: رسوم التوصيل لا تُكتب من العميل — جدول المنشآت غير مقروء ولا مكتوب
-- لـ anon (0002)، والتحديث المباشر من الموظف محصور بصفه، والحارس (trigger)
-- يقيّد أي قيمة بأعلى حد تحدده الإدارة.

-- دوال داخلية: لا تُنشر عبر الـ API (تُستدعى من الدوال المُعرَّفة والـ trigger فقط)
revoke execute on function public.delivery_fee_for(uuid) from public, anon, authenticated;
revoke execute on function public.delivery_fee_cap() from public, anon, authenticated;
revoke execute on function public.guard_delivery_fee() from public, anon, authenticated;
revoke execute on function public.order_invoice_text(uuid, text) from public, anon, authenticated;


