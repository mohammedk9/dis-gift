-- ============================================================
-- هدية | Lean MVP — 0010_loyalty.sql
-- نقاط تصدرها المنشأة: تُمنح بعد مسح الباركود، وتُعتمد عند اكتمال الطلب
-- ============================================================
-- قواعد ثابتة في هذا الإصدار:
--  1) النقاط **استحقاق وعرض فقط** في هذه المرحلة: لا استبدال، ولا خصم،
--     ولا رصيد مالي. لا يوجد جدول محافظ ولا أرصدة نقدية.
--  2) الرصيد لا يُخزَّن كعدّاد: هو مجموع صفوف status = 'applied' في
--     points_ledger. لا مجال لاختلاف العدّاد عن السجل.
--  3) الدفتر **إضافي فقط**: لا حذف، ولا تعديل على المبلغ أو الطرفين.
--     التعديل الوحيد المسموح: pending → applied/cancelled (حارس trigger).
--  4) نقطة واحدة لكل طلب (unique(order_id)): لا تكرار للنقاط على الطلب نفسه.
--  5) النقاط تُمنح من المنشأة بعد مسح كود الطلب، ولا تُعتمد إلا عند
--     اكتمال الطلب. الطلب الملغي لا يُعتمد له أي نقطة أبداً.
--  6) الكود المستخدم في الباركود هو نفس code الطلب (6 خانات hex):
--     متوافق مع Code 39 بلا تعديل، ولا يحتاج توليداً جديداً.
-- ============================================================

-- ---------- 0) نوعا الدفتر + سقف الإدارة ----------
do $$ begin create type public.points_entry as enum ('grant','adjust');
exception when duplicate_object then null; end $$;
do $$ begin create type public.points_status as enum ('pending','applied','cancelled');
exception when duplicate_object then null; end $$;

-- ASSUMPTION: لا توجد قيمة نقاط محددة في المتطلبات. 100 نقطة سقفاً أعلى
--   مبدئياً لكل طلب حتى يقرره الأدمن. حذف الإعداد يصفّره ⇒ لا نقاط تُمنح
--   (اتجاه آمن: لا استحقاق مخترع نيابة عن المنشآت).
insert into public.app_settings (key, value, description) values
 ('points_hard_cap', '100'::jsonb,
  'الحد الأعلى المطلق للنقاط التي يمكن منحها على طلب واحد. حذف الإعداد يصفّره.')
on conflict (key) do nothing;

-- ---------- 1) إعدادات النقاط على المنشأة ----------
alter table public.restaurants add column if not exists points_enabled boolean not null default false;
alter table public.restaurants add column if not exists points_per_order int not null default 0;
alter table public.restaurants add column if not exists points_max_per_order int not null default 0;

do $$ begin
  alter table public.restaurants add constraint restaurants_points_nonneg
    check (points_per_order >= 0 and points_max_per_order >= 0);
exception when duplicate_object then null; end $$;

create or replace function public.points_hard_cap() returns int
language sql stable set search_path = public as $$
  select greatest(coalesce((public.cfg('points_hard_cap') #>> '{}')::int, 0), 0);
$$;

-- حارس على جدول المنشآت: يعمل على أي مسار كتابة (RPC أو تحديث مباشر
-- من صاحب المنشأة عبر RLS)، فلا يمكن تجاوز سقف الإدارة ولا كتابة قيمة سالبة.
create or replace function public.guard_points_settings() returns trigger
language plpgsql set search_path = public as $$
declare v_cap int := public.points_hard_cap();
begin
  if new.points_per_order < 0 or new.points_max_per_order < 0 then
    raise exception 'points_invalid: القيم لا تكون سالبة';
  end if;
  if new.points_per_order > v_cap or new.points_max_per_order > v_cap then
    raise exception 'points_limit: السقف الأعلى % نقطة', v_cap;
  end if;
  -- الحد الأقصى لا يقل عن الافتراضي: لا إعداد متناقض
  if new.points_max_per_order < new.points_per_order then
    new.points_max_per_order := new.points_per_order;
  end if;
  return new;
end $$;

drop trigger if exists trg_restaurants_points on public.restaurants;
create trigger trg_restaurants_points before insert or update on public.restaurants
  for each row execute function public.guard_points_settings();

-- ---------- 2) دفتر النقاط (إضافي فقط) ----------
create table if not exists public.points_ledger (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  device_id     uuid not null,
  order_id      uuid unique references public.orders(id) on delete cascade,
  entry_type    public.points_entry not null default 'grant',
  status        public.points_status not null default 'pending',
  points        int not null check (points > 0),
  note          text,
  granted_by    uuid,
  applied_at    timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists idx_points_device  on public.points_ledger (device_id, created_at desc);
create index if not exists idx_points_rest    on public.points_ledger (restaurant_id, created_at desc);

-- الحارس: لا حذف ولا تعديل إلا pending → applied/cancelled.
-- ملاحظة مقصودة: لأن الحارس يمنع DELETE، فإن حذف صف مرتبط (طلب أو منشأة)
-- يُرفض أيضاً بسبب الحذف المتتالي (on delete cascade). لا يوجد في المنتج أي
-- مسار يحذف طلباً أو منشأة (الإيقاف يتم بحالة status)، وأي مسار حذف مستقبلي
-- يجب أن يتعامل مع الدفتر صراحةً بدل تجاوز الحارس.
create or replace function public.guard_points_ledger() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'points_ledger إضافي فقط: لا حذف';
  end if;
  if old.status <> 'pending' or new.status not in ('applied','cancelled') then
    raise exception 'points_ledger: التعديل المسموح هو pending → applied/cancelled فقط';
  end if;
  if new.points <> old.points
     or new.entry_type <> old.entry_type
     or new.order_id is distinct from old.order_id
     or new.device_id <> old.device_id
     or new.restaurant_id <> old.restaurant_id
     or new.granted_by is distinct from old.granted_by
     or new.created_at <> old.created_at then
    raise exception 'points_ledger إضافي فقط: لا يمكن تغيير مبلغ النقاط أو أطرافه';
  end if;
  return new;
end $$;

drop trigger if exists trg_points_ledger_guard on public.points_ledger;
create trigger trg_points_ledger_guard before update or delete on public.points_ledger
  for each row execute function public.guard_points_ledger();

alter table public.points_ledger enable row level security;
-- لا سياسة قراءة/كتابة لأي دور تطبيقي: القراءة عبر الدوال (security definer) فقط.

-- ============================================================
-- 3) إعدادات النقاط: صاحب المنشأة يحددها بنفسه
--    التحقق على السيرفر: قيم غير سالبة + داخل سقف الإدارة.
-- ============================================================
create or replace function public.set_restaurant_points(
  p_enabled boolean, p_per_order int default 0, p_max int default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rest uuid; v_cap int; v_max int;
begin
  select restaurant_id into v_rest from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_rest is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  if coalesce(p_per_order, 0) < 0 or coalesce(p_max, 0) < 0 then
    return jsonb_build_object('ok', false, 'error', 'points_invalid');
  end if;

  v_cap := public.points_hard_cap();
  if coalesce(p_per_order, 0) > v_cap or coalesce(p_max, 0) > v_cap then
    return jsonb_build_object('ok', false, 'error', 'points_limit', 'max', v_cap);
  end if;

  v_max := greatest(coalesce(p_max, 0), coalesce(p_per_order, 0));

  update public.restaurants
     set points_enabled = coalesce(p_enabled, false),
         points_per_order = coalesce(p_per_order, 0),
         points_max_per_order = v_max
   where id = v_rest;

  return jsonb_build_object('ok', true, 'points_enabled', coalesce(p_enabled, false),
                            'points_per_order', coalesce(p_per_order, 0),
                            'points_max_per_order', v_max, 'cap', v_cap);
end $$;

-- ============================================================
-- 4) منح النقاط بعد مسح الباركود — مرة واحدة لكل طلب
--    طلب غير مكتمل ⇒ صف pending (يُعتمد عند الاكتمال)
--    طلب مكتمل   ⇒ يُعتمد فوراً
--    طلب ملغي    ⇒ لا نقاط إطلاقاً
-- ============================================================
create or replace function public.staff_grant_points(p_order uuid, p_points int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o record; r record; v_points int; v_cap int; v_balance int;
  v_status public.points_status; v_id uuid;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;
  if not public.is_staff_of(o.restaurant_id) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select * into r from public.restaurants where id = o.restaurant_id;
  if not r.points_enabled then
    return jsonb_build_object('ok', false, 'error', 'points_disabled');
  end if;

  -- طلب ملغي أو لم يحضر: لا استحقاق أبداً
  if o.status in ('cancelled','no_show') then
    return jsonb_build_object('ok', false, 'error', 'invalid_transition', 'status', o.status);
  end if;

  if exists (select 1 from public.points_ledger where order_id = p_order) then
    return jsonb_build_object('ok', false, 'error', 'points_already_granted');
  end if;

  -- المبلغ: ما يكتبه الموظف، وإلا الافتراضي الذي حددته المنشأة
  v_points := coalesce(p_points, r.points_per_order);
  if v_points is null or v_points <= 0 then
    return jsonb_build_object('ok', false, 'error', 'points_invalid',
                              'default_points', r.points_per_order);
  end if;

  v_cap := case when r.points_max_per_order > 0
                then least(r.points_max_per_order, public.points_hard_cap())
                else public.points_hard_cap() end;
  if v_points > v_cap then
    return jsonb_build_object('ok', false, 'error', 'points_limit', 'max', v_cap);
  end if;

  v_status := case when o.status = 'completed' then 'applied'::public.points_status
                                              else 'pending'::public.points_status end;

  begin
    insert into public.points_ledger
      (restaurant_id, device_id, order_id, entry_type, status, points, note,
       granted_by, applied_at)
    values (r.id, o.device_id, p_order, 'grant', v_status, v_points,
            'نقاط من ' || r.name, auth.uid(),
            case when v_status = 'applied' then now() else null end)
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'points_already_granted');
  end;

  insert into public.events (device_id, restaurant_id, order_id, type, meta)
  values (o.device_id, r.id, p_order, 'points_granted',
          jsonb_build_object('points', v_points, 'status', v_status));

  select coalesce(sum(points), 0) into v_balance
    from public.points_ledger where device_id = o.device_id and status = 'applied';

  return jsonb_build_object('ok', true, 'points', v_points, 'status', v_status,
                            'order_id', p_order, 'code', o.code,
                            'customer_balance', v_balance);
end $$;

-- ============================================================
-- 5) البحث بكود الطلب — أساس صفحة المسح (r/scan.html)
--    نفس code المطبوع في الباركود: 6 خانات hex، بلا تعديل.
-- ============================================================
create or replace function public.staff_order_by_code(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; o record; r record; l record; v_code text;
begin
  select restaurant_id into v_id from public.restaurant_staff where user_id = auth.uid() limit 1;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'no_restaurant'); end if;

  -- الكود كما يُقرأ من الباركود: نتجاهل أي رموز محيطة قبل التحقق
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_code !~ '^[0-9A-F]{6}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_order_code');
  end if;

  select * into o from public.orders where code = v_code and restaurant_id = v_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  select * into r from public.restaurants where id = o.restaurant_id;
  select * into l from public.points_ledger where order_id = o.id;

  return jsonb_build_object(
    'ok', true,
    'order', jsonb_build_object(
      'id', o.id, 'code', o.code, 'status', o.status, 'order_type', o.order_type,
      'subtotal', o.subtotal, 'discount', o.discount_amount,
      'delivery_fee', o.delivery_fee, 'total', o.order_total,
      'awaiting_price_confirmation', (o.price_confirmed_at is null),
      'customer_name', o.customer_name,
      'customer_phone', case when o.phone_shared then o.customer_phone
                             else public.mask_phone(o.customer_phone) end,
      'phone_shared', o.phone_shared,
      'address', o.address, 'pickup_slot', o.pickup_slot, 'note', o.note,
      'created_at', o.created_at, 'completed_at', o.completed_at,
      'gift_code', (select dg.code from public.daily_gifts dg where dg.id = o.gift_id),
      'gift_kind', (select dg.gift_kind from public.daily_gifts dg where dg.id = o.gift_id),
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'name', name_snapshot, 'qty', qty, 'line_total', line_total)), '[]'::jsonb)
                 from public.order_items i where i.order_id = o.id)
    ),
    'points', jsonb_build_object(
      'granted', l.points,
      'status', l.status,
      'entry_type', l.entry_type,
      'at', l.created_at, 'applied_at', l.applied_at,
      'customer_balance', (select coalesce(sum(points), 0) from public.points_ledger
                            where device_id = o.device_id and status = 'applied')
    ),
    'settings', jsonb_build_object(
      'points_enabled', r.points_enabled,
      'points_per_order', r.points_per_order,
      'points_max_per_order', r.points_max_per_order,
      'points_cap', public.points_hard_cap()
    )
  );
end $$;

-- ============================================================
-- 6) رصيد العميل وسجل نقاطه (عرض فقط — لا استبدال في هذه المرحلة)
-- ============================================================
create or replace function public.customer_points(p_device uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_balance int; v_entries jsonb;
begin
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

-- ============================================================
-- 7) دورة حالة الطلب — الرسوم عند COMPLETED، والنقاط تُعتمد معه
--    new → accepted → preparing → ready → completed
--    أي حالة أخرى → cancelled | no_show  (بلا رسوم وبلا نقاط)
-- ============================================================
create or replace function public.transition_order(
  p_order uuid, p_to public.order_status, p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ord record; frm public.order_status; actor public.app_role;
  v_fee numeric; v_period text; v_net numeric; v_base numeric; v_points int := 0;
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

    -- === النقاط: تُعتمد هنا فقط ===
    -- الصف المعلَّق (pending) يصبح applied. النقاط لا تُعتمد على طلب لم يكتمل.
    update public.points_ledger
       set status = 'applied', applied_at = now()
     where order_id = p_order and status = 'pending';

    select coalesce(sum(points), 0) into v_points
      from public.points_ledger
     where order_id = p_order and status = 'applied';

    if v_points > 0 then
      insert into public.notifications
        (recipient_device_id, restaurant_id, order_id, type, title, body)
      values (ord.device_id, ord.restaurant_id, p_order, 'points_applied',
              'أُضيفت نقاطك', 'طلب ' || ord.code || ' — ' || v_points || ' نقطة');
    end if;

    insert into public.events (device_id, restaurant_id, gift_id, order_id, type, meta)
    values (ord.device_id, ord.restaurant_id, ord.gift_id, p_order, 'order_completed',
            jsonb_build_object('total', ord.order_total, 'fee', v_fee,
                               'delivery_fee', ord.delivery_fee, 'points', v_points));
  end if;

  -- طلب ملغي / لم يحضر: النقاط المعلَّقة تُلغى ولا تُعتمد أبداً
  if p_to in ('cancelled','no_show') then
    update public.points_ledger
       set status = 'cancelled'
     where order_id = p_order and status = 'pending';
  end if;

  return jsonb_build_object('ok', true, 'status', p_to, 'points', v_points,
                            'platform_fee',
                            case when p_to = 'completed' then v_fee else 0 end);
end $$;

-- ============================================================
-- 8) توسيع حمولات القراءة بالنقاط (استحقاق وعرض فقط)
--    نفس التوقيع ونفس النوع — استبدال آمن (create or replace).
-- ============================================================
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
      -- نقاط الطلب: صف واحد لكل طلب (أو null إن لم تُمنح بعد)
      'points', (select pl.points from public.points_ledger pl where pl.order_id = o.id),
      'points_status', (select pl.status from public.points_ledger pl where pl.order_id = o.id),
      'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'name', name_snapshot, 'qty', qty, 'line_total', line_total)), '[]'::jsonb)
                 from public.order_items i where i.order_id = o.id)
    ) order by o.created_at desc), '[]'::jsonb)
    from public.orders o
    where o.restaurant_id = v_id and (p_status is null or o.status::text = p_status)));
end $$;

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
    -- النقاط: لا تدخل في أي رقم مالي — عرض تشغيلي فقط
    'points_enabled',   (select points_enabled from public.restaurants where id = v_id),
    'points_per_order', (select points_per_order from public.restaurants where id = v_id),
    'points_granted',   (select coalesce(sum(points),0) from public.points_ledger
                           where restaurant_id = v_id and status = 'applied' and created_at >= since),
    'points_pending',   (select count(*) from public.points_ledger
                           where restaurant_id = v_id and status = 'pending'),
    'points_customers', (select count(distinct device_id) from public.points_ledger
                           where restaurant_id = v_id and status = 'applied'),
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

-- الشكل تغيّر من مصفوفة إلى كائن: رصيد النقاط يحتاج مكاناً واحداً للقراءة.
create or replace function public.customer_orders(p_device uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
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
      where o.device_id = p_device), '[]'::jsonb));
$$;

create or replace function public.order_invoice_text(p_order uuid, p_title text default 'فاتورة طلب')
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  o record; r record; g record; it record; pl record;
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

  -- النقاط المعتمدة فقط تُطبع (المعلَّقة ليست استحقاقاً بعد)
  select * into pl from public.points_ledger
   where order_id = p_order and status = 'applied';
  if found then
    v_out := v_out || 'النقاط المكتسبة: ' || pl.points || E'\n';
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

-- ---------- 9) منيو المنشأة: إظهار وعد النقاط للعميل قبل الطلب ----------
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
        'points_enabled', points_enabled, 'points_per_order', points_per_order,
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

-- ---------- 10) كشف الحساب: النقاط عرض معلوماتي فقط (لا تدخل المبالغ) ----------
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
    -- النقاط: لا قيمة نقدية لها في هذه المرحلة — تُعرض للعلم فقط
    'points_granted', (select coalesce(sum(points),0) from public.points_ledger
      where restaurant_id = v_id and status = 'applied'
        and to_char(created_at at time zone 'Asia/Riyadh','YYYY-MM') = v_per),
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

-- ---------- 11) مؤشرات الإدارة: كتلة النقاط ----------
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

    -- النقاط: بلا أي قيمة نقدية — مراقبة تبنّي المنشآت فقط
    'points', jsonb_build_object(
      'restaurants_enabled', (select count(*) from public.restaurants where points_enabled),
      'granted', (select coalesce(sum(points),0) from public.points_ledger
                   where status = 'applied' and created_at >= since),
      'orders_with_points', (select count(*) from public.points_ledger
                   where status = 'applied' and created_at >= since),
      'pending', (select count(*) from public.points_ledger where status = 'pending'),
      'cancelled', (select count(*) from public.points_ledger where status = 'cancelled'),
      'customers', (select count(distinct device_id) from public.points_ledger
                     where status = 'applied'),
      'redemption', 'غير مُفعَّل في هذه المرحلة (استحقاق وعرض فقط)'),

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
-- 12) الصلاحيات
-- ============================================================
grant execute on function public.set_restaurant_points(boolean, int, int) to authenticated;
grant execute on function public.staff_grant_points(uuid, int) to authenticated;
grant execute on function public.staff_order_by_code(text) to authenticated;
grant execute on function public.customer_points(uuid) to authenticated;
grant execute on function public.transition_order(uuid, public.order_status, text) to authenticated;
grant execute on function public.restaurant_dashboard(int) to authenticated;
grant execute on function public.restaurant_orders(text) to authenticated;
grant execute on function public.restaurant_statement(text) to authenticated;
grant execute on function public.admin_kpis(int) to authenticated;
grant execute on function public.customer_order(uuid, text) to anon, authenticated;
grant execute on function public.customer_orders(uuid) to anon, authenticated;
grant execute on function public.restaurant_menu(uuid) to anon, authenticated;

-- دوال داخلية وحُرّاس: لا تُنشر عبر الـ API
revoke execute on function public.points_hard_cap() from public, anon, authenticated;
revoke execute on function public.guard_points_settings() from public, anon, authenticated;
revoke execute on function public.guard_points_ledger() from public, anon, authenticated;
revoke execute on function public.order_invoice_text(uuid, text) from public, anon, authenticated;

-- دفتر النقاط: لا قراءة ولا كتابة مباشرة من المتصفح.
-- القراءة عبر الدوال (security definer) والكتابة عبر staff_grant_points فقط،
-- والحارس (trigger) يمنع أي حذف أو تعديل على المبلغ.
alter table public.points_ledger enable row level security;
revoke all on public.points_ledger from anon, authenticated;

-- ملاحظة: النقاط لا تدخل في restaurant_ledger ولا في monthly_statements
-- ولا في platform_fee — لا أثر مالي لها في هذه المرحلة.
