// How zigsaw starts an app on Electron's runtime, loaded with -r before the
// app itself: what the app's own copy of Electron would have given it.
'use strict';
const { app } = require('electron');
const path = require('path');

// Electron tells a packaged app from one under development by its program's
// name, which here is electron.exe for every app.
process.env.ELECTRON_FORCE_IS_PACKAGED = 'true';
process.env.ELECTRON_IS_DEV = '0';

// The app sees its arguments as `electron <app> ...` would give them, without
// the two that loaded this; a second start's arguments too, where Chromium
// puts its own switches between them.
function hide(argv) {
  const at = argv.findIndex((a, i) => i > 0 && typeof a === 'string' && path.resolve(a).toLowerCase() === __filename.toLowerCase());
  if (at < 0) return;
  argv.splice(at, 1);
  const r = argv.findIndex((a, i) => i > 0 && i < at && (a === '-r' || a === '--require'));
  if (r >= 0) argv.splice(r, 1);
}
hide(process.argv);
const emit = app.emit;
app.emit = function (name, ...rest) {
  if (name === 'second-instance' && Array.isArray(rest[1])) hide(rest[1]);
  return emit.call(this, name, ...rest);
};

// Each app its own taskbar button, as zigsaw's shortcuts name it. Electron
// would otherwise name every app on this program after it, the first time one
// needs a name (a notification, a recent document).
const id = process.env.ZIGSAW_ID;
if (id && id.length + 'Zigsaw.'.length <= 128) {
  const appId = 'Zigsaw.' + id;
  app.setAppUserModelId(appId);
  app.on('browser-window-created', (_event, window) => window.setAppDetails({ appId }));
}
