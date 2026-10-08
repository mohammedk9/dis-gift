/* ============================================================
   apply-migration.cjs — تطبيق هجرة SQL على قاعدة البيانات الحيّة
   الاستخدام:
     npm run db:migrate                 # آخر ملف هجرة (بالرقم)
     npm run db:migrate -- 0007_whatsapp
   يقرأ DATABASE_URL أو DIRECT_URL من .env (بلا حزم إضافية للقراءة)،
   ويحتاج حزمة `pg`:  npm i -D pg
   كل هجرة تُنفَّذ داخل معاملة واحدة — أي خطأ يُلغي التطبيق بالكامل.
   ============================================================ */
const fs = require('fs');
const path = require('path');

const MIGRATION_DIR = path.join(__dirname, '..', 'supabase', 'migrations');

function loadEnv() {
  const file = path.join(__dirname, '..', '.env');
  if (!fs.existsSync(file)) return {};
  const out = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    out[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
  return out;
}

function pickMigration(arg) {
  const files = fs.readdirSync(MIGRATION_DIR).filter(f => f.endsWith('.sql')).sort();
  if (!files.length) throw new Error('لا توجد هجرات في ' + MIGRATION_DIR);
  if (!arg) return files[files.length - 1];
  const name = arg.endsWith('.sql') ? arg : arg + '.sql';
  if (!files.includes(name)) throw new Error('هجرة غير موجودة: ' + name);
  return name;
}

(async () => {
  const env = { ...loadEnv(), ...process.env };
  const url = env.DATABASE_URL || env.DIRECT_URL;
  if (!url) {
    console.error('FAIL  لا يوجد DATABASE_URL أو DIRECT_URL في .env');
    process.exit(1);
  }

  let Client;
  try {
    ({ Client } = require('pg'));
  } catch {
    console.error('FAIL  حزمة pg غير مثبّتة. شغّل:  npm i -D pg');
    console.error('      أو الصق ملف الهجرة في Supabase → SQL Editor.');
    process.exit(1);
  }

  const name = pickMigration(process.argv[2]);
  const sql = fs.readFileSync(path.join(MIGRATION_DIR, name), 'utf8');
  const client = new Client({ connectionString: url });

  try {
    await client.connect();
    await client.query('begin');
    await client.query(sql);
    await client.query('commit');
    const statements = (sql.match(/;\s*$/gm) || []).length;
    console.log('PASS  تم تطبيق ' + name + ' (' + statements + ' عبارة) داخل معاملة واحدة');
    process.exit(0);
  } catch (e) {
    try { await client.query('rollback'); } catch {}
    console.error('FAIL  ' + name + ': ' + e.message);
    process.exit(1);
  } finally {
    await client.end().catch(() => {});
  }
})();
