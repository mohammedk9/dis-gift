const fs = require('fs');
let s = fs.readFileSync('supabase/migrations/0003_functions.sql', 'utf8');
// Strip BOM and normalize line endings
s = s.replace(/^\xEF\xBB\xBF/, '').replace(/\r\n/g, '\n');
const anchors = {
gp_tail: "'prep_time_min', r.prep_time_min\n      ),\n   -- ====================\n   -- 1) هدية اليوم",
orph_526: "end $$;\n$$;\nend $$;\n  select r.id, v_order, 'order_new', 'لديك طلب جديد',\n         'طلب ' || v_code || ' — ' || v_total || ' ر.س'\n    from public.restaurant_staff rs where rs.restaurant_id = r.id;\n\n  insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)\ncreate or replace function public.restaurant_orders",
orph_882: "      from public.restaurant_ledger l join public.orders o on o.id = l.order_id\n      where l.restaurant_id = v_id and l.statement_period = v_per),\n    'periods', (select coalesce(jsonb_agg(statement_period order by statement_period desc), '[]'::jsonb)\n      from (select statement_period from public.monthly_statements\n             where restaurant_id = v_id) s));\nend $$;\n  values (p_device, r.id, 'order_contact', 'granted',",
orph_872: "    address = coalesce(p_address, address), area_id = coalesce(p_area, area_id),\n    description = coalesce(p_description, description), logo_url = coalesce(p_logo, logo_url),\n    cover_url = coalesce(p_cover, cover_url),\n    pickup_enabled = coalesce(p_pickup, pickup_enabled),\n    delivery_enabled = coalesce(p_delivery, delivery_enabled),\n    prep_time_min = coalesce(p_prep, prep_time_min),\n    opening_hours = coalesce(p_hours, opening_hours)\n   where id = v_rest;\n  return jsonb_build_object('ok', true);\nend $$;\n\ncreate or replace function public.admin_set_offer",
orph_861: "return jsonb_build_object('ok', true);\nend $$;\n\ncreate or replace function public.admin_set_offer",
orph_888: "  values (p_device, r.id, 'order_contact', 'granted',\n          coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));\n\n  if p_consent_marketing then\n    insert into public.consents (device_id, restaurant_id, consent_type, consent_status, policy_version)\n      values (p_device, r.id, 'marketing', 'granted',\n              coalesce(public.cfg('policy_version') #>> '{}','v1-unverified'));\n  end if;\n\n  return jsonb_build_object('ok', true, 'order_id', v_order, 'code', v_code,\n                            'subtotal', v_sub, 'discount', v_disc, 'total', v_total);\nend $$;\n\n  insert into public.events (device_id, gift_id, restaurant_id, type)\n  values (p_device, new_gift, picked.restaurant_id, 'gift_open');\n\n  return public.gift_payload(new_gift);\nexception when unique_violation then\n  select id into new_gift from public.daily_gifts\n   where device_id = p_device and gift_date = v_today;\n  return public.gift_payload(new_gift);\nend $$;\n",
orph_910: "    'offer', jsonb_build_object('title', o.title, 'description', o.description,\n                                'expires_at', o.active_until)\n  );\nend $$;\nend $$;\n"
};
let ok = true;
for (const [k, v] of Object.entries(anchors)) {
  const i = s.indexOf(v);
  if (i < 0) { ok = false; console.log(k.padEnd(12), 'MISSING'); }
  else { console.log(k.padEnd(12), 'FOUND @', i); }
}
console.log(ok ? 'ALL ANCHORS OK' : 'SOME MISSING');
process.exit(ok ? 0 : 1);