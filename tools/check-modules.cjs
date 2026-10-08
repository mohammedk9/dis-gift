/* فحص بنية كل وحدة JS مضمّنة في HTML + الوحدات المشتركة (بلا تنفيذ) */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const SKIP = new Set(['node_modules', 'tmp', '.git', 'dist', 'build']);
// المجلد المؤقت خارج المستودع حتى لا يترك الملفات وراءه
const OUT = fs.mkdtempSync(path.join(os.tmpdir(), 'hadiya-mods-'));

const pages = [];
(function walk(dir) {
  for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(f.name)) continue;
    const p = path.join(dir, f.name);
    if (f.isDirectory()) walk(p);
    else if (f.name.endsWith('.html')) pages.push(p);
  }
})('.');

let bad = 0, checked = 0;
const syntaxCheck = (code, label) => {
  const file = path.join(OUT, label.replace(/[\\/]/g, '_') + '.mjs');
  fs.writeFileSync(file, code);
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
    console.log('PASS  ' + label);
    checked++;
  } catch (e) {
    bad++;
    console.log('FAIL  ' + label + '\n' + (e.stderr || e.message).toString());
  }
};

for (const page of pages) {
  const html = fs.readFileSync(page, 'utf8');
  const re = /<script type="module">([\s\S]*?)<\/script>/g;
  let m, i = 0;
  while ((m = re.exec(html))) syntaxCheck(m[1], page + ' #' + (++i));
}

for (const f of ['assets/js/core.js', 'assets/js/ui.js',
  'assets/js/auth-flows.js', 'assets/js/whatsapp.js', 'assets/js/barcode.js']) {
  if (fs.existsSync(f)) syntaxCheck(fs.readFileSync(f, 'utf8'), f);
}

try { fs.rmSync(OUT, { recursive: true, force: true }); } catch {}
console.log('\n' + (bad === 0 ? '>>> ALL ' + checked + ' MODULES PARSE'
  : '>>> ' + bad + ' BROKEN MODULE(S)'));
process.exit(bad === 0 ? 0 : 1);
