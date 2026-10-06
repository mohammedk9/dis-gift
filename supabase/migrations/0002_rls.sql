-- ============================================================
-- هدية | Lean MVP — 0002_rls.sql   (Row Level Security)
-- ============================================================
-- نموذج الوصول:
--   * العميل: غير مسجّل (anonymous). لا يقرأ أي جدول مباشرة.
--     كل عملياته تمر عبر Functions من类型 SECURITY DEFINER
--     (0003_functions.sql) التي تتحقق من device_id.
--   * المطعم: Auth + restaurant_staff  → يرى مطعمه فقط.
--   * Admin : admin_users             → يرى كل شيء.
--   * العروض (offers) غير قابلة للقراءة من anon إطلاقاً
--     لأن الخصم يجب أن يكون مفاجئاً قبل الفتح.
-- ============================================================

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

create or replace function public.is_staff_of(p_restaurant uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.restaurant_staff rs
    where rs.restaurant_id = p_restaurant and rs.user_id = auth.uid()
  ) or public.is_admin();
$$;

-- ---------- 1) profiles ----------
alter table public.profiles enable row level security;
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ---------- 2) areas ----------
alter table public.areas enable row level security;
drop policy if exists areas_public_read on public.areas;
create policy areas_public_read on public.areas
  for select using (is_active or public.is_admin());
-- الإدارة وحدها تضيف الأحياء (من صفحة الإعدادات)
drop policy if exists areas_admin_write on public.areas;
create policy areas_admin_write on public.areas
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 3) restaurants ----------
alter table public.restaurants enable row level security;
drop policy if exists restaurants_public_read on public.restaurants;
create policy restaurants_public_read on public.restaurants
  for select using (status = 'active' or public.is_staff_of(id) or owner_id = auth.uid());
drop policy if exists restaurants_staff_write on public.restaurants;
create policy restaurants_staff_write on public.restaurants
  for update using (public.is_staff_of(id) or owner_id = auth.uid())
  with check (public.is_staff_of(id) or owner_id = auth.uid());
-- INSERT يتم عبر Function (تسجيل مطعم جديد) لمنع الانتحال

-- ---------- 4) restaurant_staff ----------
alter table public.restaurant_staff enable row level security;
drop policy if exists staff_select on public.restaurant_staff;
create policy staff_select on public.restaurant_staff
  for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists staff_admin_write on public.restaurant_staff;
create policy staff_admin_write on public.restaurant_staff
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 5) restaurant_locations ----------
alter table public.restaurant_locations enable row level security;
drop policy if exists loc_public_read on public.restaurant_locations;
create policy loc_public_read on public.restaurant_locations
  for select using (true);
drop policy if exists loc_staff_write on public.restaurant_locations;
create policy loc_staff_write on public.restaurant_locations
  for all using (public.is_staff_of(restaurant_id))
  with check (public.is_staff_of(restaurant_id));
-- ---------- 6) menu ----------
alter table public.menu_categories enable row level security;
drop policy if exists cat_public_read on public.menu_categories;
create policy cat_public_read on public.menu_categories
  for select using (is_active or public.is_staff_of(restaurant_id));
drop policy if exists cat_staff_write on public.menu_categories;
create policy cat_staff_write on public.menu_categories
  for all using (public.is_staff_of(restaurant_id))
  with check (public.is_staff_of(restaurant_id));

alter table public.menu_items enable row level security;
drop policy if exists items_public_read on public.menu_items;
create policy items_public_read on public.menu_items
  for select using (true);   -- المنيو داخل المنصة بعد فتح الهدية
drop policy if exists items_staff_write on public.menu_items;
create policy items_staff_write on public.menu_items
  for all using (public.is_staff_of(restaurant_id))
  with check (public.is_staff_of(restaurant_id));

-- ---------- 7) pickup_slots ----------
alter table public.pickup_slots enable row level security;
drop policy if exists slots_public_read on public.pickup_slots;
create policy slots_public_read on public.pickup_slots
  for select using (true);
drop policy if exists slots_staff_write on public.pickup_slots;
create policy slots_staff_write on public.pickup_slots
  for all using (public.is_staff_of(restaurant_id))
  with check (public.is_staff_of(restaurant_id));

-- ---------- 8) offers — لا قراءة عامة إطلاقاً ----------
alter table public.offers enable row level security;
drop policy if exists offers_staff_read on public.offers;
create policy offers_staff_read on public.offers
  for select using (public.is_staff_of(restaurant_id));
drop policy if exists offers_staff_write on public.offers;
create policy offers_staff_write on public.offers
  for all using (public.is_staff_of(restaurant_id))
  with check (public.is_staff_of(restaurant_id));

-- ---------- 9) daily_gifts — anon لا يقرأ ----------
alter table public.daily_gifts enable row level security;
drop policy if exists gifts_staff_read on public.daily_gifts;
create policy gifts_staff_read on public.daily_gifts
  for select using (public.is_staff_of(restaurant_id));

-- ---------- 10) gift_redemptions ----------
alter table public.gift_redemptions enable row level security;
drop policy if exists redemptions_staff_read on public.gift_redemptions;
create policy redemptions_staff_read on public.gift_redemptions
  for select using (public.is_staff_of(restaurant_id));

-- ---------- 11) orders ----------
alter table public.orders enable row level security;
drop policy if exists orders_staff_read on public.orders;
create policy orders_staff_read on public.orders
  for select using (public.is_staff_of(restaurant_id));

alter table public.order_items enable row level security;
drop policy if exists order_items_staff_read on public.order_items;
create policy order_items_staff_read on public.order_items
  for select using (exists (select 1 from public.orders o
                             where o.id = order_id and public.is_staff_of(o.restaurant_id)));

alter table public.order_events enable row level security;
drop policy if exists order_events_staff_read on public.order_events;
create policy order_events_staff_read on public.order_events
  for select using (exists (select 1 from public.orders o
                             where o.id = order_id and public.is_staff_of(o.restaurant_id)));
-- ---------- 12) consents ----------
alter table public.consents enable row level security;
drop policy if exists consents_staff_read on public.consents;
create policy consents_staff_read on public.consents
  for select using (public.is_staff_of(restaurant_id));
-- INSERT عبر save_consent() فقط

-- ---------- 13) ledger / statements ----------
alter table public.restaurant_ledger enable row level security;
drop policy if exists ledger_staff_read on public.restaurant_ledger;
create policy ledger_staff_read on public.restaurant_ledger
  for select using (public.is_staff_of(restaurant_id));
drop policy if exists ledger_admin_write on public.restaurant_ledger;
create policy ledger_admin_write on public.restaurant_ledger
  for update using (public.is_admin()) with check (public.is_admin());

alter table public.monthly_statements enable row level security;
drop policy if exists statements_staff_read on public.monthly_statements;
create policy statements_staff_read on public.monthly_statements
  for select using (public.is_staff_of(restaurant_id));
drop policy if exists statements_admin_write on public.monthly_statements;
create policy statements_admin_write on public.monthly_statements
  for update using (public.is_admin()) with check (public.is_admin());

-- ---------- 14) events — staff لمطعمهم + Admin ----------
alter table public.events enable row level security;
drop policy if exists events_admin_read on public.events;
create policy events_admin_read on public.events
  for select using (public.is_admin());
drop policy if exists events_staff_read on public.events;
create policy events_staff_read on public.events
  for select using (public.is_staff_of(restaurant_id));

-- ---------- 15) notifications ----------
alter table public.notifications enable row level security;
drop policy if exists notif_staff_read on public.notifications;
create policy notif_staff_read on public.notifications
  for select using (recipient_user_id = auth.uid()
                    or (restaurant_id is not null and public.is_staff_of(restaurant_id)));
drop policy if exists notif_staff_update on public.notifications;
create policy notif_staff_update on public.notifications
  for update using (recipient_user_id = auth.uid()
                    or (restaurant_id is not null and public.is_staff_of(restaurant_id)));

-- ---------- 16) admin_users ----------
alter table public.admin_users enable row level security;
drop policy if exists admin_users_admin_only on public.admin_users;
create policy admin_users_admin_only on public.admin_users
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 17) ad_slots (مرساة فقط) ----------
alter table public.ad_slots enable row level security;
drop policy if exists ads_public_read on public.ad_slots;
create policy ads_public_read on public.ad_slots
  for select using (is_active);
drop policy if exists ads_admin_write on public.ad_slots;
create policy ads_admin_write on public.ad_slots
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 18) app_settings ----------
alter table public.app_settings enable row level security;
drop policy if exists settings_public_read on public.app_settings;
create policy settings_public_read on public.app_settings
  for select using (true);
drop policy if exists settings_admin_write on public.app_settings;
create policy settings_admin_write on public.app_settings
  for all using (public.is_admin()) with check (public.is_admin());

-- ---------- 19) منع الكتابة المباشرة من anon على جداول حساسة ----------
revoke insert, update, delete on public.orders           from anon;
revoke insert, update, delete on public.order_items      from anon;
revoke insert, update, delete on public.daily_gifts       from anon;
revoke insert, update, delete on public.gift_redemptions  from anon;
revoke insert, update, delete on public.restaurant_ledger from anon;
revoke insert, update, delete on public.consents          from anon;
revoke insert, update, delete on public.events            from anon;
revoke all                     on public.restaurants       from anon;