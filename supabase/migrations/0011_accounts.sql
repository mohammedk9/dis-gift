-- 0011_accounts.sql — الهوية على Supabase
-- ============================================================
-- المشكلة: معرّف العميل كان يُرسَل من المتصفح (p_device من localStorage)
--          فيمكن انتحال أي عميل، وتنتقل الهدية والطلبات مع المتصفح لا مع الحساب.
-- الحل:   p_device يُعاد كتابته داخل كل دالة من auth.uid() — تلقائياً وبلا استثناء.
--          لا يستطيع العميل تمرير معرّف غيره، ولا العمل بلا حساب أصلاً.
-- ============================================================

-- ---------- هوية العميل ----------
-- تُعيد حساب الجلسة الحالية (auth.uid) وتتجاهل ما أرسله المتصفح.
-- تُرفض الجلسات المجهولة: لا هدية ولا طلب ولا كود بلا تسجيل دخول.
create or replace function public.assert_self(p_device uuid)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = 'P0001',
      hint = 'يجب تسجيل الدخول أولاً';
  end if;
  return v_uid;
end $$;

-- ---------- ربط صفوف العميل بحسابه ----------
-- orders.user_id كان موجوداً في المخطط ولا يُعبَّأ أبداً — نُعبّئه الآن تلقائياً.
-- المعرّف المخزَّن في device_id هو حساب المصادقة نفسه، فيتنقّل
-- الهدية والطلب والنقاط مع الحساب أينما سجّل الدخول.
create or replace function public.sync_order_user_id() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null then new.user_id := new.device_id; end if;
  return new;
end $$;
drop trigger if exists trg_orders_sync_user on public.orders;
create trigger trg_orders_sync_user before insert or update of device_id on public.orders
  for each row execute function public.sync_order_user_id();

create or replace function public.sync_notification_user_id() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.recipient_user_id is null then new.recipient_user_id := new.recipient_device_id; end if;
  return new;
end $$;
drop trigger if exists trg_notifications_sync_user on public.notifications;
create trigger trg_notifications_sync_user before insert on public.notifications
  for each row execute function public.sync_notification_user_id();

-- ---------- حماية الدوال ----------
-- إعادة تعريف كل دالة يتصل بها العميل، مع سطر الحماية في مستهلها.
-- لا يتغيّر أي منطق آخر: الجسم منسوخ حرفياً من آخر هجرة.

-- create_order  (المصدر: 0009_consents.sql:170)
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
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- customer_ad  (المصدر: 0009_consents.sql:749)
create or replace function public.customer_ad(p_device uuid, p_restaurant uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a record; v_ads boolean;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- customer_confirm_order_price  (المصدر: 0008_delivery.sql:438)
create or replace function public.customer_confirm_order_price(
  p_device uuid, p_code text, p_expected_total numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- customer_consents  (المصدر: 0009_consents.sql:682)
create or replace function public.customer_consents(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_active jsonb; v_history jsonb;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- customer_notifications  (المصدر: 0003_functions.sql:504 — حُوّلت من SQL إلى plpgsql)
create or replace function public.customer_notifications(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  p_device := public.assert_self(p_device);
  return (
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'type', type, 'title', title, 'body', body,
           'is_read', is_read, 'at', created_at) order by created_at desc), '[]'::jsonb)
  from (select * from public.notifications
         where recipient_device_id = p_device order by created_at desc limit 20) n
  );
end $$;

-- customer_order  (المصدر: 0010_loyalty.sql:542)
create or replace function public.customer_order(p_device uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; r record;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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
      -- النقاط المعتمدة على هذا الطلب (null إن لم تُمنح أو لم تُعتمد بعد)
      'points', (select pl.points from public.points_ledger pl
                  where pl.order_id = o.id and pl.status = 'applied'),
      'points_status', (select pl.status from public.points_ledger pl where pl.order_id = o.id),
      'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
      'gift_kind', (select dg.gift_kind from public.daily_gifts dg where dg.id = o.gift_id),
      'whatsapp_shared_at', o.whatsapp_shared_at,
      'payment_note', 'الدفع يتم مباشرة للمطعم.'
    ),
    'points_balance', (select coalesce(sum(points),0) from public.points_ledger
                        where device_id = p_device and status = 'applied'),
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

-- customer_order_share  (المصدر: 0009_consents.sql:582)
create or replace function public.customer_order_share(p_device uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; r record; v_text text;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- customer_orders  (المصدر: 0010_loyalty.sql:595 — حُوّلت من SQL إلى plpgsql)
create or replace function public.customer_orders(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  p_device := public.assert_self(p_device);
  return (
  select jsonb_build_object(
    'ok', true,
    'points_balance', (select coalesce(sum(points),0) from public.points_ledger
                        where device_id = p_device and status = 'applied'),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', o.code, 'status', o.status, 'total', o.order_total,
               'order_type', o.order_type, 'created_at', o.created_at,
               'restaurant', r.name, 'logo_url', r.logo_url,
               'points', (select pl.points from public.points_ledger pl
                           where pl.order_id = o.id and pl.status = 'applied'))
             order by o.created_at desc)
      from public.orders o join public.restaurants r on r.id = o.restaurant_id
      where o.device_id = p_device), '[]'::jsonb))
  );
end $$;

-- customer_points  (المصدر: 0010_loyalty.sql:294)
create or replace function public.customer_points(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_balance int; v_entries jsonb;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
  -- الرصيد = مجموع الصفوف المعتمدة فقط. لا عدّاد مخزَّن.
  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where device_id = p_device and status = 'applied';

  select coalesce(jsonb_agg(jsonb_build_object(
           'restaurant', r.name, 'points', l.points, 'status', l.status,
           'entry_type', l.entry_type, 'at', l.created_at, 'applied_at', l.applied_at,
           'code', o.code, 'order_total', o.order_total) order by l.created_at desc), '[]'::jsonb)
    into v_entries
    from (select * from public.points_ledger
           where device_id = p_device order by created_at desc limit 50) l
    join public.restaurants r on r.id = l.restaurant_id
    left join public.orders o on o.id = l.order_id;

  return jsonb_build_object('ok', true, 'balance', v_balance, 'entries', v_entries,
    'redeemable', false,
    'note', 'النقاط استحقاق وعرض فقط في هذه المرحلة — لا استبدال ولا خصم ولا رصيد مالي.');
end $$;

-- open_daily_gift  (المصدر: 0003_functions.sql:118)
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
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

  -- قيمة الهدية: داخل النطاق الذي وافقت عليه المنشأة، ولا تقل عن الحد الأدنى العام
  if picked.kind = 'free_item' then
    -- صنف مجاني: القيمة المعروضة 0، والهدية هي الصنف نفسه
    v_disc := 0;
  elsif picked.max_value = 0 then
    -- المنشأة اختارت عرضاً بلا خصم (هدية رمزية فقط)
    v_disc := 0;
  else
    v_min_eff := greatest(picked.min_value, v_floor);
    if v_min_eff > picked.max_value then v_min_eff := picked.max_value; end if;
    v_disc := public.pick_discount(picked.id, v_min_eff, picked.max_value,
                                   p_device, v_today, v_step);
    if picked.kind = 'percent' and v_disc > 100 then v_disc := 100; end if;
  end if;

  insert into public.daily_gifts
    (device_id, gift_date, offer_id, restaurant_id, gift_kind,
     discount_value, gift_item_id, gift_label)
  values (p_device, v_today, picked.id, picked.restaurant_id, picked.kind,
          v_disc, picked.gift_item_id, picked.gift_label)
  returning id into new_gift;

  insert into public.events (device_id, gift_id, restaurant_id, type)
  values (p_device, new_gift, picked.restaurant_id, 'gift_open');

  return public.gift_payload(new_gift);

exception when unique_violation then
  -- سباق: جهازان فتحا في اللحظة نفسها → القيد يمنع الازدواج
  select id into new_gift from public.daily_gifts
   where device_id = p_device and gift_date = v_today;
  return public.gift_payload(new_gift);
end $$;

-- set_consent  (المصدر: 0009_consents.sql:150)
create or replace function public.set_consent(
  p_device uuid, p_restaurant uuid, p_type public.consent_type, p_granted boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- set_order_delivery  (المصدر: 0009_consents.sql:393)
create or replace function public.set_order_delivery(
  p_device uuid, p_code text, p_type public.order_type,
  p_address text default null, p_slot time default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; r record; v_addr text; v_fee numeric; v_total numeric; v_confirm boolean;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- set_order_phone  (المصدر: 0009_consents.sql:342)
create or replace function public.set_order_phone(
  p_device uuid, p_code text, p_phone text, p_consent boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; v_phone text; v_shared boolean;
begin
  -- الهوية من الجلسة: أي قيمة أخرى قادمة من المتصفح تُتجاهل
  p_device := public.assert_self(p_device);
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

-- ---------- كود الهدية لا يُسلَّم عند الفتح ----------
-- كان gift_payload يُرجع الكود لأي متصفح بمفتاح anon قبل وجود أي طلب.
-- الكود الآن يظهر فقط لصاحب الطلب داخل صفحات طلباته (customer_order / customer_orders).

-- gift_payload (المصدر: 0008_delivery.sql:501) — حُذف السطر code, g.code
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

