#!/usr/bin/env node
/* Runner: apply rules1 + rules2 + gift.html specifics. Reports every MISS. */
const fs = require('fs');
const path = require('path');
const { R: R1 } = require('./emoji-rules1.cjs');
const { R: R2 } = require('./emoji-rules2.cjs');

const CHECK = '<svg class="ico" width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="m8.5 12.5 2.5 2.5 4.5-5" stroke="#fff" stroke-width="2"/></svg>';
const GIFT18 = '<svg class="ico" width="36" height="36" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M9 2c-1.1 0-2 .9-2 2v2h10V4c0-1.1-.9-2-2-2h-6zM4 7v11c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V7H4zm3 4h2v5H7v-5zm4 0h2v5h-2v-5zm4 0h2v5h-2v-5z"/></svg>';
const STORE24 = '<svg class="ico" width="24" height="24" viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" stroke="currentColor" stroke-width="2"/><polyline points="9 22 9 12 15 12 15 22" stroke="currentColor" stroke-width="2"/></svg>';
const ALERT40 = '<svg class="ico" width="40" height="40" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg>';

const R3 = [
  { file: 'gift.html', from: "bigValue = '🎁';", to: `bigValue = '${GIFT18}';` },
  { file: 'gift.html', from: 'color:var(--orange-deep);display:grid;place-items:center;font-size:24px;flex:none">🏪</div>`}',
    to: `color:var(--orange-deep);display:grid;place-items:center;font-size:0;flex:none">${STORE24}</div>\`}` },
  { file: 'gift.html', from: '✅ ستُضاف هديتك للطلب تلقائياً عند إتمام الطلب.', to: `${CHECK} ستُضاف هديتك للطلب تلقائياً عند إتمام الطلب.` },
  { file: 'gift.html', from: "toast('🎁 لديك هدية اليوم!')", to: "toast('لديك هدية اليوم!')" },
  { file: 'gift.html', from: '<div style="font-size:40px">⚠️</div>', to: `<div style="font-size:40px">${ALERT40}</div>` }
];

let changed = 0; const misses = [];
for (const r of [...R1, ...R2, ...R3]) {
  const p = path.join(process.cwd(), r.file);
  if (!fs.existsSync(p)) { misses.push(`${r.file}: FILE MISSING`); continue; }
  const c = fs.readFileSync(p, 'utf8');
  if (c.includes(r.from)) {
    fs.writeFileSync(p, c.replace(r.from, r.to), 'utf8');
    changed++;
  } else {
    misses.push(`${r.file}: ${JSON.stringify(r.from.slice(0, 55))}`);
  }
}
console.log(`changed=${changed}`);
console.log(misses.length ? 'MISSES:\n' + misses.join('\n') : 'no misses');
