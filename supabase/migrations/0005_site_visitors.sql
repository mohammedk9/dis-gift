-- عداد الزوار الفريدين في الصفحة الرئيسية.
-- يعتمد على device_id الموجود في events، لذلك لا يخزن بيانات شخصية جديدة.

create or replace function public.site_visitor_count()
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(distinct device_id)
    from public.events
   where type = 'page_view'
     and device_id is not null;
$$;

revoke all on function public.site_visitor_count() from public;
grant execute on function public.site_visitor_count() to anon, authenticated;