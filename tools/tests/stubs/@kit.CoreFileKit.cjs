// Test stand-in for @kit.CoreFileKit: the few fileIo calls the app's
// UI-free modules use, on top of node:fs.
const fs = require('node:fs');
exports.fileIo = {
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 0o100, TRUNC: 0o1000 },
  accessSync: (p) => fs.existsSync(p),
  readTextSync: (p) => fs.readFileSync(p, 'utf8'),
  openSync: (p) => ({ fd: fs.openSync(p, 'w') }),
  writeSync: (fd, text) => fs.writeSync(fd, text),
  closeSync: (f) => fs.closeSync(f.fd),
  renameSync: (a, b) => fs.renameSync(a, b)
};
