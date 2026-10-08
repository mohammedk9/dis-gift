/* فحص دخان محلي: سيرفر ثابت مؤقت + التأكد أن كل صفحة/مرجع داخلي موجود */
const http = require('http');
const fs = require('fs');
const path = require('path');

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json', '.png': 'image/png'
};
const root = process.cwd();

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let p = path.join(root, decodeURIComponent(url.pathname));
  if (fs.existsSync(p) && fs.statSync(p).isDirectory()) p = path.join(p, 'index.html');
  if (!fs.existsSync(p)) { res.writeHead(404); return res.end('404'); }
  res.writeHead(200, { 'content-type': TYPES[path.extname(p)] || 'application/octet-stream' });
  fs.createReadStream(p).pipe(res);
});

const PAGES = ['index.html', 'login.html', 'register.html', 'gift.html', 'menu.html',
  'checkout.html', 'order.html', 'orders.html', 'notices.html', 'account.html',
  'r/', 'r/orders.html', 'r/scan.html', 'r/profile.html', 'admin/', 'admin/restaurants.html',
  'admin/settings.html'];
const ASSETS = ['assets/js/core.js', 'assets/js/ui.js', 'assets/js/auth-flows.js',
  'assets/js/whatsapp.js', 'assets/js/barcode.js', 'assets/js/vendor/supabase.js',
  'assets/css/app.css', 'sw.js', 'assets/js/runtime-config-live.js', 'assets/icon.svg',
  'manifest.webmanifest'];

server.listen(4321, async () => {
  let bad = 0;
  for (const u of [...PAGES, ...ASSETS]) {
    const r = await fetch('http://localhost:4321/' + u);
    const body = r.ok ? await r.text() : '';
    if (!r.ok) bad++;
    console.log((r.ok ? 'OK   ' : 'BAD  ') + String(r.status).padEnd(4) + u +
      (r.ok ? '  ' + body.length + ' bytes' : ''));
  }

  const refs = new Set();
  for (const f of PAGES.concat(ASSETS).filter(u => u.endsWith('.html'))) {
    const rel = f.replace(/\\/g, '/');
    const html = fs.readFileSync(f, 'utf8');
    for (const m of html.matchAll(/(?:href|src)="([^"#?:]+)"/g))
      refs.add(path.posix.normalize(path.posix.join(path.posix.dirname(rel), m[1])));
    for (const m of html.matchAll(/from '(\.[^']+)'/g))
      refs.add(path.posix.normalize(path.posix.join(path.posix.dirname(rel), m[1])));
  }

  console.log('\n--- internal references ---');
  for (const ref of [...refs].sort()) {
    if (ref.includes('${') || ref.includes('}')) continue;   // قوالب JS المضمّنة
    const ok = fs.existsSync(path.join(root, ref));
    if (!ok) bad++;
    console.log((ok ? 'OK   ' : 'MISS ') + ref);
  }

  server.close();
  console.log('\n' + (bad === 0 ? '>>> SMOKE OK' : '>>> ' + bad + ' PROBLEM(S)'));
  process.exit(bad ? 1 : 0);
});
