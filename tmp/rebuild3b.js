/* === Chunk 3: replacements 6-10 === */
const fs = require('fs');
const p = 'supabase/migrations/0003_functions.sql';
let s = fs.readFileSync(p, 'utf8');

// 6) update_restaurant_profile — complete SET clause
s = s.replace(anchors.urp_tail, anchors.urp_tail +
    "\n       address = coalesce(p_address, address), area_id = coalesce(p_area, area_id),\n       description = coalesce(p_description, description), logo_url = coalesce(p_logo, logo_url),\n       cover_url = coalesce(p_cover, cover_url),\n       pickup_enabled = coalesce(p_pickup, pickup_enabled),\n       delivery_enabled = coalesce(p_delivery, delivery_enabled),\n       prep_time_min = coalesce(p_prep, prep_time_min),\n       opening_hours = coalesce(p_hours, opening_hours)\n      where id = v_rest;\n     return jsonb_build_object('ok', true);\n     end $$;");

// 7) admin_set_restaurant — return + end
s = s.replace(anchors.asr_tail, anchors.asr_tail + "\n     return jsonb_build_object('ok', true);\n   end $$;");

// 8) admin_close_period — body before admin_kpis
s = s.replace(anchors.acp_begin, anchors.acp_begin +
    "\n       if not public.is_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;\n       update public.monthly_statements set status = 'closed' where statement_period = p_period;\n       update public.restaurant_ledger set billing_status = 'billed'\n        where statement_period = p_period and billing_status = 'unbilled';\n       return jsonb_build_object('ok', true, 'period', p_period);\n     end $$;\n     -- ====================\n     -- 11) Admin KPIs — بدون أي benchmark مخترع\n     -- ====================");

// 9) remove orphan blocks
[anchors.orph_526, anchors.orph_882, anchors.orph_872, anchors.orph_861, anchors.orph_888, anchors.orph_910].forEach(a => {
  const i = s.indexOf(a);
  if (i < 0) { console.error('ORPHAN NOT FOUND:', a.slice(0, 60)); process.exit(1); }
  s = s.slice(0, i) + s.slice(i + a.length);
});

// 10) move grants+revokes to the end
const gstart = s.indexOf('-- 12) الصلاحيات');
const gend = s.indexOf('revoke all on public.restaurant_staff       from anon;') +
             'revoke all on public.restaurant_staff       from anon;'.length;
const grants = s.slice(gstart, gend);
s = s.slice(0, gstart) + s.slice(gend);
const lastEnd = s.lastIndexOf('end $$;');
s = s.slice(0, lastEnd + 'end $$;'.length) + '\n' + grants + '\n';

fs.writeFileSync(p, s, 'utf8');
console.log('written, len:', s.length);

const lib = require('libpg-query');
try { lib.parse(s); console.log('libpg-query: PARSE OK'); process.exit(0); }
catch (e) { console.error('PARSE FAIL:', e.sqlDetails?.message, '@', e.sqlDetails?.cursorPosition); process.exit(1); }