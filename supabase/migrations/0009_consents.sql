-- ============================================================
-- هدية | Lean MVP — 0009_consents.sql
-- الموافقة مُقيَّدة بغرضها: تُخزَّن بنص الغرض + نسخة السياسة + الوقت
-- ============================================================
-- قواعد ثابتة في هذا الإصدار:
--  1) رقم الجوال ليس ثمناً لاستخدام المنصة:
--     مشاركته **اختيارية للاستلام** وشرط للتوصيل فقط (المندوب يحتاجه).
--     من يستلم بنفسه لا يُطلب منه رقم ولا موافقة.
--  2) المشاركة حالة على الطلب (orders.phone_shared) لا نصّاً في الموافقة فقط،
--     والمنشأة ترى الرقم **مقنّعاً** (05••••1234) ما لم يوافق العميل.
--  3) عمود orders.customer_phone مسحوب من anon و authenticated:
--     القراءة تمر عبر دوال security definer وحدها، فلا يمكن تسريبه
--     من المتصفح حتى لو تغيّرت سياسة RLS لاحقاً.
--  4) كل موافقة تُسجَّل بنص الغرض كما رآه العميل، وبنسخة السياسة، ووقتها،
--     ومصدرها (order / account / rpc). والسحب لا يمحو السجل:
--     يُضاف صف جديد بحالة revoked ووقت سحب، والرفض يُسجَّل صراحةً أيضاً.
--  5) موافقة التسويق ليست شرطاً لأي طلب، ولا تُعرض رسالة تسويقية
--     من منشأة إلا لمن موافقته فعّالة.
-- ============================================================

-- ---------- 0) إعدادات: نص الغرض لكل نوع ----------
-- النص المُخزَّن في صف الموافقة هو النص المعروض نفسه (بعد استبدال اسم المنشأة).
-- ASSUMPTION: هذه صياغات تشغيلية وليست نصاً نظامياً معتمداً — تحتاج مراجعة
--   الجهة المختصة. ولأن النص يُحفظ داخل كل موافقة، تحديث الصياغة لاحقاً
--   لا يغيّر دلالة موافقة قديمة.
insert into public.app_settings (key, value, description) values
 ('consent_purpose_order_contact',
  to_jsonb('مشاركة رقم جوالي مع {restaurant} للتواصل معي بخصوص هذا الطلب فقط: تأكيد الطلب أو تغييره أو تسليمه.'::text),
  'نص غرض موافقة التواصل. {restaurant} يُستبدل باسم المنشأة عند التسجيل.'),
 ('consent_purpose_marketing',
  to_jsonb('إرسال عروض وتسويق من {restaurant} إليّ عبر واتساب أو إشعارات المنصة.'::text),
  'نص غرض موافقة التسويق. {restaurant} يُستبدل باسم المنشأة عند التسجيل.')
on conflict (key) do nothing;

-- ---------- 1) أعمدة الموافقات + حالة مشاركة الجوال ----------
alter table public.consents add column if not exists purpose text;
alter table public.consents add column if not exists withdrawn_at timestamptz;
alter table public.consents add column if not exists source text;
alter table public.consents add column if not exists order_id uuid
  references public.orders(id) on delete set null;

create index if not exists idx_consents_device_type
  on public.consents (device_id, consent_type, created_at desc);

alter table public.orders add column if not exists phone_shared boolean not null default false;

-- الجوال لم يبقَ إلزامياً على مستوى الجدول: الإلزام صار للتوصيل وحده
-- (القيد أدناه)، والاستلام قد يكون بلا رقم جوال إطلاقاً.
alter table public.orders alter column customer_phone drop not null;

-- NOT VALID: لا نتحقق من الصفوف القديمة عند الإضافة (قد تحمل صيغة جوال
-- مختلفة عمّا يفرضه التطبيق الآن)، والقيد يُفرض على كل كتابة جديدة.
do $$ begin
  alter table public.orders add constraint orders_delivery_phone_required
    check (order_type <> 'delivery'
           or (customer_phone is not null and customer_phone ~ '^05[0-9]{8}$')) not valid;
exception when duplicate_object then null; end $$;

-- تعبئة السجلات السابقة: قبل هذه الهجرة كانت الموافقة إلزامية على كل طلب،
-- فحالة الجوال «مشارَك» والغرض «صياغة ما قبل 0009». التعبئة تعمل **مرة واحدة**
-- (علامة في app_settings): إعادة تشغيل الملف لا تعيد كتابة سجل قديم.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'consents_backfill_at') then
    update public.orders
       set phone_shared = true
     where customer_phone is not null and phone_shared = false;

    update public.consents
       set purpose = coalesce(purpose, case consent_type
             when 'order_contact' then 'مشاركة رقم الجوال مع المنشأة للتواصل بخصوص الطلب (صياغة ما قبل 0009).'
             else 'تلقي عروض وتسويق من المنشأة (صياغة ما قبل 0009).'
           end),
           source  = coalesce(source, 'pre_0009'),
           withdrawn_at = case when consent_status = 'revoked'
                               then coalesce(withdrawn_at, created_at) else withdrawn_at end
     where purpose is null or source is null;

    insert into public.app_settings (key, value, description)
    values ('consents_backfill_at', to_jsonb(now()),
            'وقت تعبئة حالة مشاركة الجوال والغرض للسجلات السابقة على 0009_consents — يمنع تكرار التعبئة.');
  end if;
end $$;

-- ============================================================
-- 2) مساعدات داخلية: نص الغرض · الموافقة الفعّالة · تقنيع الرقم
-- ============================================================
create or replace function public.consent_purpose(
  p_type public.consent_type, p_restaurant uuid
) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_key text; v_tpl text; v_name text;
begin
  v_key := case p_type when 'order_contact' then 'consent_purpose_order_contact'
                       else 'consent_purpose_marketing' end;
  v_tpl := public.cfg(v_key) #>> '{}';
  if v_tpl is null then return null; end if;
  select name into v_name from public.restaurants where id = p_restaurant;
  return replace(v_tpl, '{restaurant}', coalesce(v_name, 'المنشأة'));
end $$;

-- الموافقة الفعّالة = آخر صف مسجَّل لنفس (الجهاز، المنشأة، الغرض) كان granted.
-- السجل لا يُحدَّث ولا يُحذف: السحب صف جديد بحالة revoked.
create or replace function public.consent_active(
  p_device uuid, p_restaurant uuid, p_type public.consent_type
) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.consent_status = 'granted'
      from public.consents c
     where c.device_id = p_device
       and c.consent_type = p_type
       and c.restaurant_id is not distinct from p_restaurant
     order by c.created_at desc, c.id desc
     limit 1), false);
$$;

-- 05••••1234 — ما تراه المنشأة ما لم يوافق العميل على المشاركة
create or replace function public.mask_phone(p_phone text)
returns text language sql immutable as $$
  select case
    when p_phone is null or length(trim(p_phone)) < 6 then null
    else substr(trim(p_phone), 1, 2) || '••••' || right(trim(p_phone), 4)
  end;
$$;

-- ============================================================
-- 3) تسجيل الموافقة/السحب — سجل مستقل لكل غرض
-- ============================================================
create or replace function public.save_consent(
  p_device uuid, p_restaurant uuid, p_type public.consent_type,
  p_status public.consent_status
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ver text := coalesce(public.cfg('policy_version') #>> '{}', 'v1-unverified');
  v_purpose text := public.consent_purpose(p_type, p_restaurant);
begin
  insert into public.consents
    (device_id, restaurant_id, consent_type, consent_status, policy_version,
     purpose, source, withdrawn_at)
  values (p_device, p_restaurant, p_type, p_status, v_ver,
          v_purpose, 'rpc',
          case when p_status = 'granted' then null else now() end);
  return jsonb_build_object('ok', true, 'policy_version', v_ver,
                            'status', p_status, 'purpose', v_purpose);
end $$;

-- واجهة الحساب: موافقة أو سحب بمنطق واحد (الغرض يحدد النص المحفوظ)
create or replace function public.set_consent(
  p_device uuid, p_restaurant uuid, p_type public.consent_type, p_granted boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  -- منشأة غير معروفة ⇒ رفض عام (لا نكشف وجود الصف من عدمه)
  if p_restaurant is not null
     and not exists (select 1 from public.restaurants where id = p_restaurant) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  return public.save_consent(p_device, p_restaurant, p_type,
           case when coalesce(p_granted, false)
                then 'granted'::public.consent_status
                else 'revoked'::public.consent_status end);
end $$;

-- ============================================================
-- 4) إنشاء الطلب — مشاركة الجوال شرط للتوصيل فقط
--    نفس التوقيع ونفس النوع — استبدال آمن (create or replace).
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
  v_phone text; v_shared boolean := false;
begin
  select * into g from public.daily_gifts
   where id = p_gift and device_id = p_device for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'gift_not_found'); end if;
  if g.status <> 'opened' then return jsonb_build_object('ok', false, 'error', 'gift_already_used'); end if;

  -- الجوال: اختياري للاستلام، وشرط للتوصيل (المندوب يحتاجه).
  -- الموافقة على المشاركة شرط للتوصيل أيضاً، ولا تُطلب ممن يستلم بنفسه.
  v_phone  := nullif(trim(coalesce(p_phone, '')), '');
  v_shared := coalesce(p_consent_order_contact, false) and v_phone is not null;

  if v_phone is not null and v_phone !~ '^05[0-9]{8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;
  if p_type = 'delivery' and v_phone is null then
    return jsonb_build_object('ok', false, 'error', 'phone_required');
  end if;
  if p_type = 'delivery' and not v_shared then
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
     customer_name, customer_phone, phone_shared, area_id, address, pickup_slot, note,
     price_confirmed_at, price_confirmed_total)
  values
    (v_code, r.id, p_device, g.id, p_type, 'new',
     v_sub, v_disc, v_fee, v_total, 0,
     p_name, v_phone, v_shared, p_area, p_address, p_slot, p_note,
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

  -- الموافقة تُسجَّل دائماً: granted عند المشاركة، وrevoked عند الرفض.
  -- الرفض صف صريح — لا نستنتج عدم الموافقة من غياب السجل.
  insert into public.consents
    (device_id, restaurant_id, consent_type, consent_status, policy_version,
     purpose, source, order_id, withdrawn_at)
  values (p_device, r.id, 'order_contact',
          case when v_shared then 'granted'::public.consent_status
                              else 'revoked'::public.consent_status end,
          coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'),
          public.consent_purpose('order_contact', r.id), 'order', v_order,
          case when v_shared then null else now() end);

  if p_consent_marketing then
    insert into public.consents
      (device_id, restaurant_id, consent_type, consent_status, policy_version,
       purpose, source, order_id, withdrawn_at)
    values (p_device, r.id, 'marketing', 'granted',
            coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'),
            public.consent_purpose('marketing', r.id), 'order', v_order, null);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'code', v_code,
                            'order_type', p_type,
                            'subtotal', v_sub, 'discount', v_disc,
                            'delivery_fee', v_fee, 'total', v_total,
                            'phone_shared', v_shared,
                            'awaiting_price_confirmation', v_confirm);
end $$;

-- ============================================================
-- 5) مشاركة/سحب الجوال لطلب قائم — العميل وجهازه فقط
--    التوصيل لا يقوم بلا رقم ولا بلا موافقة، والاستلام لا يحتاج أياً منهما.
-- ============================================================
create or replace function public.set_order_phone(
  p_device uuid, p_code text, p_phone text, p_consent boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; v_phone text; v_shared boolean;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  if o.status <> 'new' then
    return jsonb_build_object('ok', false, 'error', 'invalid_delivery_change', 'status', o.status);
  end if;

  v_phone  := nullif(trim(coalesce(p_phone, '')), '');
  v_shared := coalesce(p_consent, false) and v_phone is not null;

  if v_phone is not null and v_phone !~ '^05[0-9]{8}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;
  -- التوصيل: لا يكفي إدخال الرقم — لا بد من موافقة صريحة على مشاركته
  if o.order_type = 'delivery' and not v_shared then
    return jsonb_build_object('ok', false, 'error',
      case when v_phone is null then 'phone_required' else 'consent_required' end);
  end if;

  update public.orders
     set customer_phone = case when v_shared then v_phone
                               else coalesce(v_phone, customer_phone) end,
         phone_shared   = v_shared
   where id = o.id;

  -- كل تغيير صف جديد بنص غرضه ووقته (لا تعديل على سجل موافقة سابق)
  insert into public.consents
    (device_id, restaurant_id, consent_type, consent_status, policy_version,
     purpose, source, order_id, withdrawn_at)
  values (o.device_id, o.restaurant_id, 'order_contact',
          case when v_shared then 'granted'::public.consent_status
                              else 'revoked'::public.consent_status end,
          coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'),
          public.consent_purpose('order_contact', o.restaurant_id), 'order', o.id,
          case when v_shared then null else now() end);

  return jsonb_build_object('ok', true, 'phone_shared', v_shared,
    'phone', case when v_shared then v_phone else public.mask_phone(v_phone) end);
end $$;

-- ============================================================
-- 6) تغيير طريقة الاستلام قبل القبول (العميل فقط، وجهازه فقط)
--    التغيير يُعيد حساب رسوم التوصيل ويُلغي أي تأكيد سعر سابق،
--    ويطلب جوالاً + موافقة مشاركة عند التحويل إلى توصيل.
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
    -- المندوب يحتاج رقم العميل: لا توصيل بلا جوال ولا بلا موافقة مشاركة
    if coalesce(trim(o.customer_phone), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'phone_required');
    end if;
    if not o.phone_shared then
      return jsonb_build_object('ok', false, 'error', 'consent_required');
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
-- 7) نص الفاتورة: لا يُطبع رقم الجوال بلا مشاركة صريحة
--    الفاتورة قد تُسلَّم للمنشأة (عبر العميل نفسه)، فلا يجوز أن تحمل
--    رقماً رفض العميل مشاركته.
-- ============================================================
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

  v_out := '🎁 ' || p_title || E'\n' ||
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

  -- الرقم يظهر فقط إذا شاركه العميل فعلاً (وإلا فهو مخفي عن المنشأة)
  v_out := v_out || 'الاسم: ' || o.customer_name || E'\n' ||
           'الجوال: ' || case when o.phone_shared then o.customer_phone
                              else 'غير مُشارَك' end || E'\n';

  if o.address is not null then v_out := v_out || 'العنوان: ' || o.address || E'\n'; end if;
  if o.note    is not null then v_out := v_out || 'ملاحظة: ' || o.note || E'\n'; end if;

  v_out := v_out || '—————' || E'\n' ||
           'الدفع يتم مباشرة مع المنشأة — لا دفع إلكتروني عبر المنصة.';
  return v_out;
end $$;

-- ============================================================
-- 8) توسيع القراءات: حالة مشاركة الجوال + الرقم المقنّع
--    نفس التوقيع ونفس النوع — استبدال آمن (create or replace).
-- ============================================================
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
      'customer_phone', o.customer_phone,
      'phone_shared', o.phone_shared,
      'address', o.address,
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

-- ---------- 9) مشاركة العميل فاتورته مع المنشأة ----------
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
    'phone_shared', o.phone_shared,
    'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
    'whatsapp_shared_at', (select x.whatsapp_shared_at from public.orders x where x.id = o.id)
  );
end $$;

-- ---------- 10) طلبات المنشأة: الرقم مقنّع ما لم يوافق العميل ----------
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
      'customer_name', o.customer_name,
      -- الرقم الكامل لا يُرسل إلا بموافقة مشاركة فعّالة على هذا الطلب
      'customer_phone', case when o.phone_shared then o.customer_phone
                             else public.mask_phone(o.customer_phone) end,
      'phone_shared', o.phone_shared,
      'phone_masked', public.mask_phone(o.customer_phone),
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

-- ---------- 11) مشاركة الموظف الفاتورة مع العميل ----------
-- إرسال الفاتورة يحتاج رقم العميل: بلا موافقة مشاركة لا يوجد رقم أصلاً.
create or replace function public.staff_order_share(p_order uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; v_to text; v_text text;
begin
  select * into o from public.orders where id = p_order;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;
  if not public.is_staff_of(o.restaurant_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  if not o.phone_shared then
    return jsonb_build_object('ok', false, 'error', 'phone_not_shared',
                              'masked_phone', public.mask_phone(o.customer_phone));
  end if;

  v_to   := public.normalize_whatsapp(o.customer_phone);
  v_text := public.order_invoice_text(o.id, 'فاتورة طلبك');
  return jsonb_build_object('ok', true, 'code', o.code, 'whatsapp', v_to,
                            'whatsapp_ready', (v_to is not null), 'invoice', v_text);
end $$;

-- ============================================================
-- 12) سجل موافقات العميل: الحالة الفعّالة + الغرض + السحب + السجل
--     كان يُعيد كل الصفوف بلا تمييز فعّال/منتهٍ — صار يُميّز بينهما.
-- ============================================================
create or replace function public.customer_consents(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_active jsonb; v_history jsonb;
begin
  -- الحالة الفعّالة: آخر صف لكل (منشأة، غرض) — هي التي تحكم فعلاً
  select coalesce(jsonb_agg(x.item order by x.at desc), '[]'::jsonb) into v_active
    from (
      select distinct on (c.restaurant_id, c.consent_type)
             c.created_at as at,
             jsonb_build_object(
               'restaurant_id', c.restaurant_id,
               'restaurant', coalesce(r.name, 'المنصة'),
               'type', c.consent_type,
               'status', c.consent_status,
               'active', (c.consent_status = 'granted'),
               'purpose', c.purpose,
               'policy_version', c.policy_version,
               'source', c.source,
               'at', c.created_at,
               'withdrawn_at', c.withdrawn_at
             ) as item
        from public.consents c
        left join public.restaurants r on r.id = c.restaurant_id
       where c.device_id = p_device
       order by c.restaurant_id, c.consent_type, c.created_at desc, c.id desc
    ) x;

  -- السجل: آخر 50 صفاً كما سُجّلت (لا شيء يُحدَّث ولا يُحذف)
  select coalesce(jsonb_agg(jsonb_build_object(
           'restaurant_id', c.restaurant_id,
           'restaurant', coalesce(r.name, 'المنصة'),
           'type', c.consent_type, 'status', c.consent_status,
           'purpose', c.purpose, 'policy_version', c.policy_version,
           'source', c.source, 'at', c.created_at, 'withdrawn_at', c.withdrawn_at
         ) order by c.created_at desc), '[]'::jsonb) into v_history
    from (select * from public.consents where device_id = p_device
           order by created_at desc limit 50) c
    left join public.restaurants r on r.id = c.restaurant_id;

  return jsonb_build_object('ok', true, 'consents', v_active, 'history', v_history);
end $$;

-- ============================================================
-- 13) بوابة التسويق: لا رسالة تسويقية بلا موافقة فعّالة
-- ============================================================
-- عدد الجمهور فقط: لا أرقام ولا معرّفات أجهزة تُعاد للمنشأة،
-- والإرسال نفسه خارج نطاق هذه المرحلة.
create or replace function public.restaurant_marketing_audience()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_count int;
begin
  select restaurant_id into v_id from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  select count(distinct c.device_id) into v_count
    from public.consents c
   where c.restaurant_id = v_id
     and c.consent_type = 'marketing'
     and public.consent_active(c.device_id, v_id, 'marketing');

  return jsonb_build_object('ok', true, 'count', v_count,
    'note', 'عدد الأجهزة ذات موافقة تسويق فعّالة. لا تُعرض أرقام ولا معرّفات.');
end $$;

-- الإعلان داخل المنصة رسالة تسويقية: لا يُعرض لمن لم يوافق على التسويق.
create or replace function public.customer_ad(p_device uuid, p_restaurant uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a record; v_ads boolean;
begin
  v_ads := coalesce((public.cfg('ads_enabled') #>> '{}')::boolean, false);
  if not v_ads then return jsonb_build_object('ok', false, 'error', 'no_ad_available'); end if;

  -- الموافقة الفعّالة شرط قبل أي محتوى تسويقي لهذه المنشأة
  if not public.consent_active(p_device, p_restaurant, 'marketing') then
    return jsonb_build_object('ok', false, 'error', 'no_marketing_consent');
  end if;

  select s.id, s.title, s.image_url into a
    from public.ad_slots s
   where s.restaurant_id = p_restaurant and s.is_active
     and (s.starts_at is null or s.starts_at <= now())
     and (s.ends_at   is null or s.ends_at   >= now())
   order by s.created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_ad_available'); end if;

  return jsonb_build_object('ok', true,
    'ad', jsonb_build_object('id', a.id, 'title', a.title, 'image_url', a.image_url));
end $$;

-- ============================================================
-- 14) جوال العميل لا يُقرأ من المتصفح
--     كل قراءات الطلب تمر عبر دوال security definer التي تقنّع الرقم
--     ما لم يوافق العميل. وسحب SELECT على العمود يجعل التسريب من
--     المتصفح مستحيلاً حتى لو تغيّرت سياسة RLS لاحقاً.
-- ============================================================
revoke select on public.orders from anon, authenticated;

grant select (id, code, restaurant_id, device_id, user_id, gift_id, order_type, status,
              subtotal, discount_amount, delivery_fee, order_total, platform_fee,
              customer_name, area_id, address, pickup_slot, note,
              price_confirmed_at, price_confirmed_total, phone_shared,
              whatsapp_shared_at, created_at, accepted_at, ready_at,
              completed_at, cancelled_at, cancel_reason, completion_code)
  on public.orders to authenticated;
-- ملاحظة: customer_phone غير مشمول عن قصد — أُسقط من القائمة أعلاه.

-- ============================================================
-- 15) الصلاحيات
-- ============================================================
grant execute on function public.save_consent(uuid, uuid, public.consent_type, public.consent_status) to anon, authenticated;
grant execute on function public.set_consent(uuid, uuid, public.consent_type, boolean) to anon, authenticated;
grant execute on function public.set_order_phone(uuid, text, text, boolean) to anon, authenticated;
grant execute on function public.customer_consents(uuid) to anon, authenticated;
grant execute on function public.customer_ad(uuid, uuid) to anon, authenticated;
grant execute on function public.restaurant_marketing_audience() to authenticated;

-- دوال داخلية: لا تُنشر عبر الـ API (تُستدعى من الدوال المُعرَّفة فقط)
revoke execute on function public.consent_purpose(public.consent_type, uuid) from public, anon, authenticated;
revoke execute on function public.consent_active(uuid, uuid, public.consent_type) from public, anon, authenticated;
revoke execute on function public.mask_phone(text) from public, anon, authenticated;

-- ملاحظة: الموافقة لا تُكتب من المتصفح مباشرة — جدول consents مسحوب من anon
-- (0003) ولا كتابة مباشرة عليه إلا عبر هذه الدوال (security definer).
