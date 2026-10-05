const fs = require('fs');
const sql = fs.readFileSync('supabase/migrations/0004_seed.sql','utf8');
const idx = sql.indexOf("'city'");
const cityEnd = sql.indexOf(');', sql.indexOf('المدينة'));
console.log('end chunk:', JSON.stringify(sql.slice(idx, cityEnd+2)));
console.log('line 55 raw:', JSON.stringify(sql.split('\n')[54]));