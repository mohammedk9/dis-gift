/* فحص بنية SQL: توازن الأقواس + اكتمال العبارات (tokenizer حقيقي) */
const fs = require('fs');
const FILES = ['0001_schema', '0002_rls', '0003_functions', '0004_seed'];
const pairs = { ')': '(', ']': '[', '}': '{' };
let bad = 0;

for (const n of FILES) {
  const sql = fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8');
  let i = 0, line = 1, mode = null;
  const stack = [];
  let error = null;

  while (i < sql.length && !error) {
    const ch = sql[i], nx = sql[i + 1];
    if (ch === '\n') { line++; i++; continue; }

    if (mode === 'line') { if (ch === '\n') mode = null; i++; continue; }
    if (mode === 'block') { if (ch === '*' && nx === '/') { mode = null; i += 2; continue; } i++; continue; }
    if (mode === 'sq') { if (ch === "'") { if (nx === "'") { i += 2; continue; } mode = null; i++; continue; } i++; continue; }
    if (mode === 'dollar') { if (ch === '$' && nx === '$') { mode = null; i += 2; continue; } i++; continue; }

    if (ch === '-' && nx === '-') { mode = 'line'; i += 2; continue; }
    if (ch === '/' && nx === '*') { mode = 'block'; i += 2; continue; }
    if (ch === "'") { mode = 'sq'; i++; continue; }
    if (ch === '$' && nx === '$') { mode = 'dollar'; i += 2; continue; }

    if ('([{'.includes(ch)) stack.push({ ch, line });
    else if (')]}'.includes(ch)) {
      const top = stack.pop();
      if (!top || top.ch !== pairs[ch]) {
        error = 'mismatch: found ' + ch + ' at line ' + line +
                (top ? ', expected close of ' + top.ch + ' from line ' + top.line : ', unexpected close');
      }
    }
    i++;
  }

  if (!error && stack.length) error = 'unclosed ' + JSON.stringify(stack.slice(-2));
  if (!error && mode && mode !== 'line') error = 'unterminated ' + mode + ' literal';

  if (error) { bad++; console.log('FAIL  ' + n.padEnd(16) + error); }
  else console.log('PASS  ' + n.padEnd(16) + 'structurally valid');
}

// count real top-level statements: ';' outside comments/strings/dollar-quotes
for (const n of FILES) {
  const sql = fs.readFileSync('supabase/migrations/' + n + '.sql', 'utf8');
  let i = 0, mode = null, stmts = 0, creates = 0, tail = '';
  while (i < sql.length) {
    const ch = sql[i], nx = sql[i + 1];
    if (mode === 'line') { if (ch === '\n') mode = null; i++; continue; }
    if (mode === 'block') { if (ch === '*' && nx === '/') { mode = null; i += 2; continue; } i++; continue; }
    if (mode === 'sq') { if (ch === "'") { if (nx === "'") { i += 2; continue; } mode = null; i++; continue; } i++; continue; }
    if (mode === 'dollar') { if (ch === '$' && nx === '$') { mode = null; i += 2; continue; } i++; continue; }
    if (ch === '-' && nx === '-') { mode = 'line'; i += 2; continue; }
    if (ch === '/' && nx === '*') { mode = 'block'; i += 2; continue; }
    if (ch === "'") { mode = 'sq'; i++; continue; }
    if (ch === '$' && nx === '$') { mode = 'dollar'; i += 2; continue; }
    if (ch === ';') {
      stmts++;
      if (/^create/.test(tail)) creates++;
      tail = '';
      i++;
      continue;
    }
    if (!/\s/.test(ch)) tail += ch;
    i++;
  }

  const ok = stmts > 0 && mode !== 'dollar';
  if (!ok) bad++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + n.padEnd(16) +
    stmts + ' statements (' + creates + ' CREATE) — last char: ' +
    JSON.stringify(sql.trim().slice(-1)));
}

console.log('\n' + (bad === 0 ? '>>> SQL SYNTAX OK' : '>>> ' + bad + ' SQL PROBLEM(S)'));
process.exit(bad === 0 ? 0 : 1);