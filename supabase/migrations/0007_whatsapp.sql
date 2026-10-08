-- ============================================================
-- هدية | Lean MVP — 0007_whatsapp.sql
-- 1) رقم واتساب لكل منشأة تستقبل عليه فاتورة الطلب
-- 2) كود قصير لكل هدية يومية (يتحقق منه الموظف في لوحة المنشأة)
-- 3) نص الفاتورة يُبنى على السيرفر (customer_order_share / staff_order_share)
-- ============================================================
-- قاعدة ثابتة في هذا الإصدار: المفتاح الدولي للسعودية 966 والجوال يبدأ بـ 5
-- (المنصة في بريدة — راجع README). التطبيع يتم على السيرفر فقط.
--
-- واتساب هنا قناةُ توصيلٍ للفاتورة، وليس نوع طلب:
--   * لا يوجد أي مسار يتجاوز النظام — الطلب يُنشأ أولاً عبر public.create_order
--     (الخصم والكود يُحسبان على السيرفر)، ثم يُرسل نص الفاتورة إلى واتساب المنشأة.
--   * order_type يبقى (pickup | delivery) بلا تغيير.
-- ============================================================

-- ---------- 1) أعمدة واتساب على المنشأة ----------
alter table public.restaurants add column if not exists whatsapp text;
alter table public.restaurants
  add column if not exists whatsapp_orders_enabled boolean not null default true;

-- الصيغة المخزّنة: 9665xxxxxxxx (بلا + وبلا مسافات)
do $$ begin
  alter table public.restaurants add constraint restaurants_whatsapp_format
    check (whatsapp is null or whatsapp ~ '^9665[0-9]{8}$');
exception when duplicate_object then null; end $$;

-- العميل لا يقرأ جدول restaurants أصلاً (revoke all ... from anon في 0002),
-- فيصل الرقم إليه عبر الدوال من نوع SECURITY DEFINER فقط.

-- ---------- 2) تطبيع رقم الواتساب (السيرفر هو المرجع) ----------
create or replace function public.normalize_whatsapp(p_input text)
returns text
language plpgsql immutable as $$
declare v_digits text;
begin
  if p_input is null then return null; end if;
  v_digits := regexp_replace(p_input, '[^0-9]', '', 'g');
  if v_digits = '' then return null; end if;

  if v_digits like '00966%' then v_digits := substr(v_digits, 3); end if;  -- 00966… → 966…
  if v_digits like '966%'   then v_digits := substr(v_digits, 4); end if;  -- إزالة مفتاح الدولة
  if v_digits like '0%'     then v_digits := substr(v_digits, 2); end if;  -- 05… → 5…

  if v_digits ~ '^5[0-9]{8}$' then return '966' || v_digits; end if;
  return null;   -- أي صيغة أخرى غير مقبولة في هذه النسخة
end $$;

-- كود قصير لكل هدية: يُطبع/يُقال للموظف، والموظف يتحقق منه في لوحة الطلبات.
create or replace function public.new_gift_code() returns text
language plpgsql volatile as $$
declare v_code text; v_try int := 0;
begin
  loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.daily_gifts where code = v_code);
    v_try := v_try + 1;
    if v_try >= 20 then exit; end if;   -- القيد الفريد يمنع أي تكرار عملياً
  end loop;
  return v_code;
end $$;

-- ---------- 3) كود الهدية اليومية ----------
alter table public.daily_gifts add column if not exists code text;

-- القيد الفريد أولاً (يسمح بـ NULL) حتى يتعذّر أي تكرار أثناء تعبئة الصفوف القديمة
do $$ begin
  alter table public.daily_gifts add constraint daily_gifts_code_key unique (code);
exception when duplicate_object then null; end $$;

-- تعبئة الكود للصفوف القديمة: نحفظ المعرّفات أولاً ثم كل صف يُعاد المحاولة عليه حتى ينجح
do $$
declare v_ids uuid[]; i int; v_code text;
begin
  select array_agg(id) into v_ids from public.daily_gifts where code is null;
  if v_ids is not null then
    for i in 1 .. array_length(v_ids, 1) loop
      loop
        v_code := public.new_gift_code();
        begin
          update public.daily_gifts set code = v_code where id = v_ids[i];
          exit;
        exception when unique_violation then
          null;   -- الكود مستخدم → جرّب كوداً آخر لنفس الصف
        end;
      end loop;
    end loop;
  end if;
end $$;

alter table public.daily_gifts alter column code set default public.new_gift_code();
alter table public.daily_gifts alter column code set not null;

-- ---------- 4) قناة تسليم الفاتورة ----------
-- يُسجَّل وقت إرسال العميل فاتورته إلى واتساب المنشأة (قناة توصيل، بلا رسوم).
alter table public.orders add column if not exists whatsapp_shared_at timestamptz;

-- ---------- 5) حفظ رقم واتساب المنشأة (صاحب المنشأة فقط) ----------
-- p_whatsapp = null أو ''  ⇒  مسح الرقم وإيقاف استقبال الطلبات عبر واتساب.
create or replace function public.set_restaurant_whatsapp(
  p_whatsapp text default null, p_enabled boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid; v_norm text;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  if p_whatsapp is null or trim(p_whatsapp) = '' then
    update public.restaurants set whatsapp = null, whatsapp_orders_enabled = false where id = v_rest;
    return jsonb_build_object('ok', true, 'whatsapp', null, 'whatsapp_orders_enabled', false);
  end if;

  v_norm := public.normalize_whatsapp(p_whatsapp);
  if v_norm is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_whatsapp');
  end if;

  update public.restaurants
     set whatsapp = v_norm,
         whatsapp_orders_enabled = coalesce(p_enabled, true)
   where id = v_rest;
  return jsonb_build_object('ok', true, 'whatsapp', v_norm,
                            'whatsapp_orders_enabled', coalesce(p_enabled, true));
end $$;

-- ---------- 6) توسيع حمولات القراءة: واتساب + كود الهدية ----------
-- نفس التوقيع ونفس النوع — استبدال آمن (create or replace).
create or replace function public.gift_payload(p_gift uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g record; r record; o record;
begin
  select * into g from public.daily_gifts where id = p_gift;
  if not found then return jsonb_build_object('ok', false, 'error', 'gift_not_found'); end if;

  select id, name, description, logo_url, cover_url, phone, address,
         pickup_enabled, delivery_enabled, prep_time_min, area_id, city, business_type,
         whatsapp, whatsapp_orders_enabled
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

-- ---------- 7) نص الفاتورة (يُبنى على السيرفر فقط) ----------
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

  v_out := '🎁 ' || p_title || E'\n' ||
           r.name || E'\n' ||
           'رقم الطلب: ' || o.code || E'\n' ||
           to_char(o.created_at at time zone 'Asia/Riyadh', 'YYYY-MM-DD HH24:MI') || E'\n' ||
           '—————' || E'\n' || v_lines || '—————' || E'\n' ||
           'الإجمالي: ' || round(o.subtotal, 2)::text || ' ر.س' || E'\n' ||
           'الخصم: -' || round(o.discount_amount, 2)::text || ' ر.س' || E'\n' ||
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

-- ---------- 8) مشاركة العميل فاتورته مع المنشأة ----------
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
    'total', o.order_total,
    'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
    'whatsapp_shared_at', (select x.whatsapp_shared_at from public.orders x where x.id = o.id)
  );
end $$;

-- ---------- 9) مشاركة الموظف فاتورة الطلب مع العميل ----------
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

  v_to   := public.normalize_whatsapp(o.customer_phone);
  v_text := public.order_invoice_text(o.id, 'فاتورة طلبك');
  return jsonb_build_object('ok', true, 'code', o.code, 'whatsapp', v_to,
                            'whatsapp_ready', (v_to is not null), 'invoice', v_text);
end $$;

-- ---------- 10) توسيع قراءة الطلب: واتساب المنشأة + كود الهدية ----------
create or replace function public.customer_order(p_device uuid, p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o record; r record;
begin
  select * into o from public.orders where code = upper(p_code) and device_id = p_device;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;
  select name, phone, address, logo_url, whatsapp, whatsapp_orders_enabled
    into r from public.restaurants where id = o.restaurant_id;
  return jsonb_build_object(
    'ok', true,
    'order', jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'order_type', o.order_type,
      'subtotal', o.subtotal, 'discount', o.discount_amount, 'total', o.order_total,
      'pickup_slot', o.pickup_slot, 'note', o.note, 'created_at', o.created_at,
      'completed_at', o.completed_at, 'customer_name', o.customer_name,
      'customer_phone', o.customer_phone, 'address', o.address,
      'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
      'gift_kind', (select dg.gift_kind from public.daily_gifts dg where dg.id = o.gift_id),
      'whatsapp_shared_at', o.whatsapp_shared_at,
      'payment_note', 'الدفع يتم مباشرة للمطعم.'
    ),
    'restaurant', jsonb_build_object('name', r.name, 'phone', r.phone,
                                     'address', r.address, 'logo_url', r.logo_url,
                                     'whatsapp', r.whatsapp,
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
      'whatsapp', r.whatsapp,
      'whatsapp_orders_enabled', r.whatsapp_orders_enabled,
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

-- ---------- 11) تسجيل منشأة جديدة (مع واتساب اختياري) ----------
-- التوقيع القديم يُحذف أولاً: وجود نسختين يخلق التباساً في PostgREST.
drop function if exists public.register_restaurant(text, text, text, int, text, boolean, boolean, public.business_type);
create or replace function public.register_restaurant(
  p_name text, p_phone text, p_address text, p_area int,
  p_description text default null, p_pickup boolean default true,
  p_delivery boolean default false,
  p_business public.business_type default 'restaurant',
  p_whatsapp text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_slug text; v_wa text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'auth_required'); end if;
  if exists (select 1 from public.restaurant_staff where user_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'already_registered');
  end if;

  -- التطبيع على السيرفر؛ الرقم غير الصالح يُرفض (العميل يمكنه تخطيه).
  if p_whatsapp is not null and trim(p_whatsapp) <> '' then
    v_wa := public.normalize_whatsapp(p_whatsapp);
    if v_wa is null then return jsonb_build_object('ok', false, 'error', 'invalid_whatsapp'); end if;
  end if;

  v_slug := regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g');
  insert into public.restaurants (name, slug, phone, address, area_id, description,
                                  pickup_enabled, delivery_enabled, status, owner_id, business_type,
                                  whatsapp, whatsapp_orders_enabled)
  values (p_name, v_slug || '-' || substr(md5(v_uid::text),1,4), p_phone, p_address, p_area,
          p_description, p_pickup, p_delivery, 'pending', v_uid, p_business,
          v_wa, (v_wa is not null))
  returning id into v_id;
  insert into public.restaurant_staff (restaurant_id, user_id, role)
  values (v_id, v_uid, 'owner');
  update public.profiles set role = 'restaurant', phone = coalesce(phone, p_phone),
       full_name = coalesce(full_name, p_name) where id = v_uid;
  return jsonb_build_object('ok', true, 'restaurant_id', v_id, 'status', 'pending',
                            'whatsapp', v_wa,
                            'whatsapp_orders_enabled', (v_wa is not null));
end $$;

-- ---------- 12) تحديث ملف المنشأة (مع واتساب) ----------
-- p_whatsapp = null ⇒ لا تغيير. لمسح الرقم استخدم set_restaurant_whatsapp(null).
drop function if exists public.update_restaurant_profile(text, text, text, int, text, text, text, boolean, boolean, int, jsonb, public.business_type);
create or replace function public.update_restaurant_profile(
  p_name text default null, p_phone text default null, p_address text default null,
  p_area int default null, p_description text default null, p_logo text default null,
  p_cover text default null, p_pickup boolean default null, p_delivery boolean default null,
  p_prep int default null, p_hours jsonb default null,
  p_business public.business_type default null,
  p_whatsapp text default null, p_whatsapp_orders boolean default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid; v_wa text;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  if p_whatsapp is not null then
    v_wa := public.normalize_whatsapp(p_whatsapp);
    if v_wa is null then return jsonb_build_object('ok', false, 'error', 'invalid_whatsapp'); end if;
  end if;

  update public.restaurants set
    name = coalesce(p_name, name), phone = coalesce(p_phone, phone),
    address = coalesce(p_address, address), area_id = coalesce(p_area, area_id),
    description = coalesce(p_description, description), logo_url = coalesce(p_logo, logo_url),
    cover_url = coalesce(p_cover, cover_url),
    pickup_enabled = coalesce(p_pickup, pickup_enabled),
    delivery_enabled = coalesce(p_delivery, delivery_enabled),
    prep_time_min = coalesce(p_prep, prep_time_min),
    opening_hours = coalesce(p_hours, opening_hours),
    business_type = coalesce(p_business, business_type),
    whatsapp = coalesce(v_wa, whatsapp),
    whatsapp_orders_enabled = coalesce(p_whatsapp_orders, whatsapp_orders_enabled)
   where id = v_rest;
  return jsonb_build_object('ok', true, 'whatsapp', coalesce(v_wa,
    (select w.whatsapp from public.restaurants w where w.id = v_rest)));
end $$;

-- ============================================================
-- 13) الصلاحيات
-- ============================================================
grant execute on function public.normalize_whatsapp(text) to anon, authenticated;
grant execute on function public.set_restaurant_whatsapp(text, boolean) to authenticated;
grant execute on function public.customer_order_share(uuid, text) to anon, authenticated;
grant execute on function public.staff_order_share(uuid) to authenticated;
grant execute on function public.register_restaurant(text, text, text, int, text, boolean, boolean, public.business_type, text) to authenticated;
grant execute on function public.update_restaurant_profile(text, text, text, int, text, text, text, boolean, boolean, int, jsonb, public.business_type, text, boolean) to authenticated;

-- دوال داخلية: لا تُنشر عبر الـ API (تُستدعى من الدوال المُعرَّفة فقط)
revoke execute on function public.order_invoice_text(uuid, text) from public, anon, authenticated;
revoke execute on function public.new_gift_code() from public, anon, authenticated;
