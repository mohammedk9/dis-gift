const lines = require('fs').readFileSync('index.html', 'utf8').split(/\r?\n/);
const needles = ['account-menu-divider', 'accountSignOut', 'accountMemberName', 'accountMember', 'accountGuest'];
lines.forEach((l, i) => {
  if (needles.some(n => l.includes(n))) console.log((i + 1) + ': ' + l.trim());
});
