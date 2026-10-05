const fs = require('fs');
const s = fs.readFileSync('supabase/migrations/0003_functions.sql', 'utf8');
console.log('CRLF?', s.includes('\r\n'));
console.log('LF only?', s.indexOf('\n') >= 0 && !s.includes('\r\n'));
console.log('gp_tail prefix @', s.indexOf("'prep_time_min', r.prep_time_min"));
console.log('len:', s.length);
console.log('first 120 raw:', JSON.stringify(s.substring(0, 120)));