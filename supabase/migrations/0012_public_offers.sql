-- ============================================================
-- هدية | Lean MVP — 0012_public_offers.sql
-- واجهة عامة للعروض النشطة.
-- ============================================================
-- الزائر غير المسجّل كان لا يملك أي مسار لقراءة العروض:
--   * offers غير قابلة للقراءة من anon (revoke في 0003 + RLS في 0002)
--   * open_daily_gift يتطلب جلسة (auth_required) — وهو مسار الفتح لا العرض
-- فترتيب العرض والفتح صار:
--   1) العرض العام هنا: يرى الزائر اسم المنشأة وعنوان الهدية (بلا قيمة ولا كود).
--   2) الفتح/الاستبدال: يبقى عبر open_daily_gift ويتطلب حساباً.
-- القيمة لا تُكشف قبل الفتح إطلاقاً — public_offers لا تُرجع أي حقل قيمة.
-- ============================================================

create or replace function public.public_offers(p_area int default null)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'restaurant_id', r.id,
           'restaurant', r.name,
           'description', r.description,
           'logo_url', r.logo_url,
           'business_type', r.business_type,
           'area_id', r.area_id,
           'offer', jsonb_build_object(
             'title', o.title,
             'description', o.description,
             'kind', o.kind,
             'expires_at', o.active_until)
         ) order by r.sort_order, r.name), '[]'::jsonb)
  from public.offers o
  join public.restaurants r on r.id = o.restaurant_id
 where o.is_enabled
   and r.status = 'active'
   and (o.active_from  is null or o.active_from  <= now())
   and (o.active_until is null or o.active_until >= now())
   and public.within_active_hours(o.active_hours)
   and (p_area is null or r.area_id is null or r.area_id = p_area);
$$;

-- الزائر المجهول يقرأ العروض النشطة؛ الكتابة والفتح يبقيان محميين.
grant execute on function public.public_offers(int) to anon, authenticated;
