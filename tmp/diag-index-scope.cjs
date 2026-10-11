const fs = require('fs');
const s = fs.readFileSync('index.html', 'utf8');

const tag = '<script type="module">';
const st = s.indexOf(tag) + tag.length;
const en = s.indexOf('</script>', st);
const mod = s.slice(st, en);

console.log('module block length:', mod.length);
console.log('defines esc?     ', /(const|let|var|function)\s+esc\b/.test(mod));
console.log('defines areaId?  ', /(const|let|var|function)\s+areaId\b/.test(mod));
console.log('esc(  calls in module:', (mod.match(/\besc\(/g) || []).length);
console.log('areaId( calls in module:', (mod.match(/\bareaId\(/g) || []).length);

console.log('\n--- module import lines ---');
mod.split(/\r?\n/).forEach((l, i) => {
  if (/^\s*import\b/.test(l)) console.log('  ' + l.trim());
});

console.log('\n--- any global assignment of esc/areaId anywhere in index.html ---');
s.split(/\r?\n/).forEach((l, i) => {
  if (/\b(window|globalThis)\.(esc|areaId)\b/.test(l)) console.log((i + 1) + ': ' + l.trim());
});

console.log('\n--- module-level declarations (top-level, indent 0) ---');
mod.split(/\r?\n/).forEach((l, i) => {
  if (/^(const|let|var|function|async function|import)\b/.test(l)) {
    console.log('  ' + l.slice(0, 90));
  }
});
