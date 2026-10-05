const fs = require('fs');
const sql = fs.readFileSync('supabase/migrations/0003_functions.sql','utf8');
console.log('count $$;:', (sql.match(/\$\$;/g)||[]).length);
console.log('count create or replace:', (sql.match(/create or replace function/g)||[]).length);