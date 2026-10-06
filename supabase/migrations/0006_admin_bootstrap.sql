-- ============================================================
-- هدية | Lean MVP — 0006_admin_bootstrap.sql
-- إصلاح ربط حساب مالك المنصة إذا شُغّل seed قبل إنشاء حساب Auth.
-- ============================================================

-- إنشاء profile وربط مالك المنصة تلقائياً عند إنشاء حسابه لاحقاً.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name',
          coalesce(new.raw_user_meta_data->>'phone', new.phone))
  on conflict (id) do nothing;

  if lower(trim(coalesce(new.email, ''))) = 'mohammdk9559@gmail.com' then
    insert into public.admin_users (user_id, role)
    values (new.id, 'admin'::public.app_role)
    on conflict (user_id) do update set role = 'admin'::public.app_role;
  end if;

  return new;
end $$;

-- Backfill للحساب الموجود مسبقاً؛ آمن عند إعادة التشغيل.
insert into public.admin_users (user_id, role)
select u.id, 'admin'::public.app_role
  from auth.users u
 where lower(trim(coalesce(u.email, ''))) = 'example@gmail.com'
on conflict (user_id) do update set role = 'admin'::public.app_role;