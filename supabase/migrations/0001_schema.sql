-- ============================================================
-- هدية | Lean MVP — 0001_schema.sql  (Supabase / PostgreSQL)
-- المدينة: بريدة — MVP فقط
-- ============================================================
create extension if not exists pgcrypto;

-- ---------- Enums ----------
-- PostgreSQL has no CREATE TYPE IF NOT EXISTS.  Keep this bootstrap file
-- safe to run against a project where the schema already exists.
do $$ begin create type public.app_role as enum ('customer','restaurant','admin');
exception when duplicate_object then null; end $$;
do $$ begin create type public.restaurant_status as enum ('pending','active','suspended','hidden');
exception when duplicate_object then null; end $$;
do $$ begin create type public.order_status as enum ('new','accepted','preparing','ready','completed','cancelled','no_show');
exception when duplicate_object then null; end $$;
do $$ begin create type public.order_type as enum ('pickup','delivery');
exception when duplicate_object then null; end $$;
do $$ begin create type public.gift_status as enum ('opened','redeemed','expired');
exception when duplicate_object then null; end $$;
do $$ begin create type public.consent_type as enum ('order_contact','marketing');
exception when duplicate_object then null; end $$;
do $$ begin create type public.consent_status as enum ('granted','revoked');
exception when duplicate_object then null; end $$;
do $$ begin create type public.ledger_entry as enum ('platform_fee','adjustment');
exception when duplicate_object then null; end $$;
do $$ begin create type public.billing_status as enum ('unbilled','billed','paid');
exception when duplicate_object then null; end $$;
do $$ begin create type public.statement_status as enum ('open','closed','paid');
exception when duplicate_object then null; end $$;
do $$ begin create type public.staff_role as enum ('owner','manager');
exception when duplicate_object then null; end $$;

-- نوع المنشأة: المنصة ليست حكراً على المطاعم
do $$ begin create type public.business_type as enum ('restaurant','cafe','salon','store','services','other');
exception when duplicate_object then null; end $$;

-- نوع الهدية: ليست خصماً فقط — قد تكون صنفاً مجانياً أو مبلغاً ثابتاً
do $$ begin create type public.offer_kind as enum ('percent','fixed_amount','free_item');
exception when duplicate_object then null; end $$;

-- ---------- 1) إعدادات يغيّرها Admin بلا كود ----------
create table if not exists public.app_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_by  uuid references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now()
);

-- ---------- 2) الأحياء المدعومة (بريدة فقط في MVP) ----------
create table if not exists public.areas (
  id         serial primary key,
  city       text not null default 'بريدة',
  name       text not null unique,
  is_active  boolean not null default true,
  sort_order int  not null default 0
);

-- ---------- 3) المستخدمون المسجلون (مطاعم + إدارة) ----------
-- العميل غير مسجّل في MVP: يُعرَّف بـ device_id فقط.
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.app_role not null default 'customer',
  full_name  text,
  phone      text,
  created_at timestamptz not null default now()
);

-- ---------- 4) المنشآت (مطاعم، كافيهات، صالونات، متاجر، خدمات) ----------
-- اسم الجدول بقي restaurants للتوافق، لكن النوع مفتوح لكل قطاع.
create table if not exists public.restaurants (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid references public.profiles(id) on delete set null,
  name             text not null,
  slug             text unique,
  description      text,
  logo_url         text,
  cover_url        text,
  phone            text,
  address          text,
  area_id          int references public.areas(id) on delete set null,
  city             text not null default 'بريدة',
  status           public.restaurant_status not null default 'pending',
  business_type    public.business_type not null default 'restaurant',
  pickup_enabled   boolean not null default true,
  delivery_enabled boolean not null default false,  -- توصيل المطعم نفسه
  prep_time_min    int not null default 20,
  opening_hours    jsonb not null default '{}'::jsonb,
  min_order_total  numeric(10,2) not null default 0,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now()
);

create table if not exists public.restaurant_staff (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  role          public.staff_role not null default 'manager',
  created_at    timestamptz not null default now(),
  unique (restaurant_id, user_id)
);

create table if not exists public.restaurant_locations (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  label         text,
  address       text,
  area_id       int references public.areas(id) on delete set null,
  lat           double precision,  -- لـ GPS لاحقاً، غير مفعّل في MVP
  lng           double precision
);
-- ---------- 5) المنيو (بدون مخزون / بدون POS) ----------
create table if not exists public.menu_categories (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name          text not null,
  sort_order    int not null default 0,
  is_active     boolean not null default true
);

create table if not exists public.menu_items (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  category_id   uuid references public.menu_categories(id) on delete set null,
  name          text not null,
  description   text,
  price         numeric(10,2) not null check (price >= 0),
  image_url     text,
  is_available  boolean not null default true,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

-- ---------- 6) أوقات الاستلام ----------
create table if not exists public.pickup_slots (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  slot_time     time not null,
  is_active     boolean not null default true,
  unique (restaurant_id, slot_time)
);

-- ---------- 7) العروض / الهدايا ----------
-- العرض ليس خصماً فقط. ثلاث أنواع:
--   percent      → خصم نسبة مئوية (10% - 20%)
--   fixed_amount → هدية بمبلغ ثابت (10 ر.س - 25 ر.س)
--   free_item    → صنف مجاني يحدده صاحب المنشأة ("قهوة مجانية")
create table if not exists public.offers (
  id             uuid primary key default gen_random_uuid(),
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  kind           public.offer_kind not null default 'percent',
  title          text not null default 'هدية',
  description    text,
  -- النطاق: نسبة % لـ percent، أو مبلغ ر.س لـ fixed_amount.
  -- 0 = هدية بلا خصم (صنف مجاني فقط). للمنشأة أن تقرر.
  min_value      numeric(10,2) not null check (min_value >= 0),
  max_value      numeric(10,2) not null check (max_value >= min_value),
  -- الصنف المجاني (يُستخدم فقط عند kind = free_item)
  gift_item_id   uuid references public.menu_items(id) on delete set null,
  gift_label     text,                       -- نص يظهر للعميل: "قهوة ساخنة مجاناً"
  daily_limit    int not null default 20 check (daily_limit > 0),
  redeemed_today int not null default 0,
  redeemed_on    date,
  active_from    timestamptz,
  active_until   timestamptz,
  active_hours   jsonb not null default '[]'::jsonb,
  is_enabled     boolean not null default true,
  created_at     timestamptz not null default now(),
  constraint offer_kind_fields check (
    (kind = 'free_item' and gift_item_id is not null)
    or (kind <> 'free_item' and gift_item_id is null)
  ),
  -- نسبة الخصم لا تتجاوز 100% عند اختيار kind = percent
  constraint offer_percent_cap check (kind <> 'percent' or max_value <= 100)
);
-- ---------- 8) الهدايا اليومية (جهاز واحد = هدية واحدة/يوم) ----------
create table if not exists public.daily_gifts (
  id             uuid primary key default gen_random_uuid(),
  device_id      uuid not null,
  gift_date      date not null default (now() at time zone 'Asia/Riyadh')::date,
  offer_id       uuid not null references public.offers(id) on delete cascade,
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  gift_kind      public.offer_kind not null default 'percent',
  -- القيمة المعروضة للعميل: نسبة، أو مبلغ ثابت، أو 0 عند صنف مجاني
  discount_value numeric(10,2) not null,
  gift_item_id   uuid references public.menu_items(id) on delete set null,
  gift_label     text,
  status         public.gift_status not null default 'opened',
  opened_at      timestamptz not null default now(),
  unique (device_id, gift_date)
);

-- ---------- 9) استبدال الهدية بطلب (unique gift_id = لا إعادة استخدام) ----------
create table if not exists public.gift_redemptions (
  id             uuid primary key default gen_random_uuid(),
  gift_id        uuid not null unique references public.daily_gifts(id) on delete cascade,
  order_id       uuid unique,
  device_id      uuid not null,
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  gift_kind      public.offer_kind not null default 'percent',
  discount_value numeric(10,2) not null,
  redeemed_at    timestamptz not null default now()
);

-- ---------- 10) الطلبات ----------
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,
  restaurant_id   uuid not null references public.restaurants(id) on delete cascade,
  device_id       uuid,
  user_id         uuid references public.profiles(id) on delete set null,
  gift_id         uuid references public.daily_gifts(id) on delete set null,
  order_type      public.order_type not null,
  status          public.order_status not null default 'new',
  subtotal        numeric(10,2) not null default 0,
  discount_amount numeric(10,2) not null default 0,
  order_total     numeric(10,2) not null default 0,
  platform_fee    numeric(10,2) not null default 0,
  customer_name   text not null,
  customer_phone  text not null,
  area_id         int references public.areas(id) on delete set null,
  address         text,
  pickup_slot     time,
  note            text,
  created_at      timestamptz not null default now(),
  accepted_at     timestamptz,
  ready_at        timestamptz,
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  cancel_reason   text,
  completion_code text,   -- أساس إضافة OTP لاحقاً
  constraint pickup_slot_required check (order_type <> 'pickup' or pickup_slot is not null)
);

create table if not exists public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  menu_item_id   uuid references public.menu_items(id) on delete set null,
  name_snapshot  text not null,
  price_snapshot numeric(10,2) not null,
  qty            int not null check (qty > 0),
  line_total     numeric(10,2) not null,
  note           text
);

create table if not exists public.order_events (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  from_status public.order_status,
  to_status   public.order_status not null,
  actor_role  public.app_role not null,
  actor_id    uuid,
  note        text,
  created_at  timestamptz not null default now()
);
-- ---------- 11) الموافقات (سجل إلزامي) ----------
create table if not exists public.consents (
  id             uuid primary key default gen_random_uuid(),
  device_id      uuid,
  user_id        uuid references public.profiles(id) on delete cascade,
  restaurant_id  uuid references public.restaurants(id) on delete cascade,
  consent_type   public.consent_type not null,
  consent_status public.consent_status not null,
  policy_version text not null,
  created_at     timestamptz not null default now()
);

-- ---------- 12) دفتر الحسابات ----------
create table if not exists public.restaurant_ledger (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null references public.restaurants(id) on delete cascade,
  order_id         uuid not null references public.orders(id) on delete cascade,
  entry_type       public.ledger_entry not null default 'platform_fee',
  order_total      numeric(10,2) not null,
  discount_amount  numeric(10,2) not null default 0,
  platform_fee     numeric(10,2) not null default 0,
  restaurant_net   numeric(10,2) not null default 0,
  statement_period text not null,        -- 'YYYY-MM'
  billing_status   public.billing_status not null default 'unbilled',
  completed_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  unique (order_id, entry_type)           -- منع تكرار الرسوم على نفس الطلب
);

create table if not exists public.monthly_statements (
  id                  uuid primary key default gen_random_uuid(),
  restaurant_id       uuid not null references public.restaurants(id) on delete cascade,
  statement_period    text not null,
  completed_orders    int not null default 0,
  total_order_value   numeric(12,2) not null default 0,
  total_discounts     numeric(12,2) not null default 0,
  total_platform_fees numeric(12,2) not null default 0,
  outstanding         numeric(12,2) not null default 0,
  status              public.statement_status not null default 'open',
  generated_at        timestamptz not null default now(),
  unique (restaurant_id, statement_period)
);

-- ---------- 13) الأحداث (قياس التحويل) ----------
create table if not exists public.events (
  id            uuid primary key default gen_random_uuid(),
  device_id     uuid,
  user_id       uuid references public.profiles(id) on delete set null,
  restaurant_id uuid references public.restaurants(id) on delete cascade,
  gift_id       uuid references public.daily_gifts(id) on delete cascade,
  order_id      uuid references public.orders(id) on delete cascade,
  type          text not null,
  meta          jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

-- ---------- 14) الإشعارات (داخل التطبيق في MVP) ----------
create table if not exists public.notifications (
  id                  uuid primary key default gen_random_uuid(),
  recipient_device_id uuid,
  recipient_user_id   uuid references public.profiles(id) on delete cascade,
  restaurant_id       uuid references public.restaurants(id) on delete cascade,
  order_id            uuid references public.orders(id) on delete cascade,
  type                text not null,
  title               text not null,
  body                text,
  is_read             boolean not null default false,
  created_at          timestamptz not null default now()
);

create table if not exists public.admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       public.app_role not null default 'admin',
  created_at timestamptz not null default now()
);

-- ---------- 15) مرساة الإعلانات (فارغة — لا نظام إعلاني في MVP) ----------
create table if not exists public.ad_slots (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  title         text,
  image_url     text,
  is_active     boolean not null default false,
  starts_at     timestamptz,
  ends_at       timestamptz,
  created_at    timestamptz not null default now()
);

-- ---------- Indexes ----------
create index if not exists idx_gifts_device_date on public.daily_gifts (device_id, gift_date desc);
create index if not exists idx_gifts_restaurant  on public.daily_gifts (restaurant_id);
create index if not exists idx_offers_restaurant on public.offers (restaurant_id) where is_enabled;
create index if not exists idx_items_restaurant  on public.menu_items (restaurant_id);
create index if not exists idx_orders_restaurant on public.orders (restaurant_id, created_at desc);
create index if not exists idx_orders_device     on public.orders (device_id, created_at desc);
create index if not exists idx_orders_status     on public.orders (status);
create index if not exists idx_events_type       on public.events (type, created_at desc);
create index if not exists idx_events_device     on public.events (device_id, created_at desc);
create index if not exists idx_events_restaurant on public.events (restaurant_id, created_at desc);
create index if not exists idx_ledger_restaurant on public.restaurant_ledger (restaurant_id, completed_at desc);
create index if not exists idx_notif_device      on public.notifications (recipient_device_id, created_at desc);

-- ---------- updated_at helper ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists trg_settings_touch on public.app_settings;
create trigger trg_settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();