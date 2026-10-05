-- ============================================================
-- هدية | Lean MVP — 0004_seed.sql
-- settings + الأحياء (بريدة) + صفحات العميل/المطعم/الإدارة
-- ============================================================
-- ⚠️ ASSUMPTION: أسماء الأحياء أدناه أسماء تشغيلية للاختبار فقط.
--    ليست قائمة أحياء رسمية — استبدلها بأسماء أحياء بريدة الفعلية
--    عبر لوحة الإدارة عند الإطلاق الحقيقي.
-- ============================================================

-- ---------- إنشاء profile تلقائي عند التسجيل ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name',
          coalesce(new.raw_user_meta_data->>'phone', new.phone))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_auth_user_created on auth.users;
create trigger trg_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- الإعدادات ----------
-- platform_fee = 0 افتراضياً. ASSUMPTION: لا توجد قيمة رسوم مُحددة في المتطلبات،
-- لذلك صفر حتى يقررها الأدمن أثناء الاختبار. لا تُفرض رسوم على أي طلب مكتمل
-- ما لم تُضبط قيمة موجبة من لوحة الإدارة.
insert into public.app_settings (key, value, description) values
 ('platform_fee', '0'::jsonb, 'رسوم المنصة الثابتة لكل طلب مكتمل (ر.س). لا تعتمد على قيمة الطلب.'),
 ('gifts_per_day', '1'::jsonb, 'عدد الهدايا لكل مستخدم يومياً.'),
 ('discount_strategy', '"uniform"'::jsonb, 'uniform | bias_min — طريقة اختيار الخصم داخل النطاق.'),
 ('discount_step', '1'::jsonb, 'granularity تقريب قيمة الخصم.'),
 ('min_discount_floor', '0'::jsonb, 'حد أدنى عام للخصم مهما سمح المطعم (0 = استخدم min_discount للمطعم).'),
 ('campaign_discount_min', '1'::jsonb, 'أقل نسبة خصم يسمح بها المدير في الحملات.'),
 ('campaign_discount_max', '100'::jsonb, 'أعلى نسبة خصم يسمح بها المدير في الحملات.'),
 ('campaign_daily_limit_max', '500'::jsonb, 'أقصى حد يومي للعرض في الحملات.'),
 ('order_timeout_minutes', '60'::jsonb, 'مهلة رفض الطلب قبل اعتباره ملغياً (يدوي في MVP).'),
 ('policy_version', '"v1-unverified"'::jsonb,
  'نسخة سياسة الموافقات. REQUIRES OFFICIAL VERIFICATION — تحتاج مراجعة الجهة المختصة.'),
 ('ads_enabled', 'false'::jsonb, 'مفتاح محجوز للإعلانات المستقبلية. غير مفعّل في MVP.'),
 ('city', '"بريدة"'::jsonb, 'المدينة.");

-- ---------- الأحياء (بيانات اختبار) ----------
insert into public.areas (name, sort_order) values
 ('حي النخيل', 1), ('حي الورود', 2), ('حي الصفراء', 3), ('حي المها', 4),
 ('حي العزيزية', 5), ('حي السلام', 6), ('حي الربيع', 7)
on conflict (name) do nothing;