/* فحص SQL بمُحلِّل PostgreSQL الحقيقي (libpg-query) — أقوى من عدّ الأقواس */
const fs = require('fs');

const FILES = ['0001_schema', '0002_rls', '0003_functions', '0004_seed',
  '0005_site_visitors', '0006_admin_bootstrap', '0007_whatsapp', '0008_delivery',
  '0009_consents', '0010_loyalty'];

(async () => {
  let parse;
  try {
    ({ parse } = require('libpg-query'));
  } catch (e) {
    console.log('SKIP  libpg-query غير متاح: ' + e.message);
    process.exit(0);
  }

  let bad = 0;
  for (const n of FILES) {
    const sql = fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8');
    try {
      await parse(sql);
      console.log('PASS  ' + n.padEnd(22) + 'PostgreSQL parser OK');
    } catch (e) {
      bad++;
      console.log('FAIL  ' + n.padEnd(22) + (e.message || String(e)));
    }
  }
  console.log('\n' + (bad === 0 ? '>>> ALL ' + FILES.length + ' MIGRATIONS PARSE IN POSTGRESQL'
    : '>>> ' + bad + ' FILE(S) REJECTED BY THE PARSER'));
  process.exit(bad === 0 ? 0 : 1);
})();
