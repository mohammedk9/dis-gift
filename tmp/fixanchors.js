const fs = require('fs');
const p = 'tmp/rebuild3.js';
let s = fs.readFileSync(p, 'utf8');

// fix 1: orph_872 indentation (2 spaces before return)
s = s.replace(
  "where id = v_rest;\n return jsonb_build_object('ok', true);\nend $$;\n\ncreate or replace function public.admin_set_offer",
  "where id = v_rest;\n  return jsonb_build_object('ok', true);\nend $$;\n\ncreate or replace function public.admin_set_offer");

// fix 2: extend orph_888 to also remove the orphaned open_daily_gift tail (901-909)
s = s.replace(
  "\n  insert into public.events (device_id, gift_id, restaurant_id, type)\";\n// 1) gift_payload",
  "\n  insert into public.events (device_id, gift_id, restaurant_id, type)\n  values (p_device, new_gift, picked.restaurant_id, 'gift_open');\n\n  return public.gift_payload(new_gift);\nexception when unique_violation then\n  select id into new_gift from public.daily_gifts\n   where device_id = p_device and gift_date = v_today;\n  return public.gift_payload(new_gift);\nend $$;\n\";\n// 1) gift_payload");

// fix 3: gend uses lastIndexOf (multiple revoke lines)
s = s.replace(
  "const gend = s.indexOf('revoke all on public.restaurant_staff       from anon;') +",
  "const gend = s.lastIndexOf('revoke all on public.restaurant_staff       from anon;') +");

fs.writeFileSync(p, s, 'utf8');
console.log('patched, len:', s.length);