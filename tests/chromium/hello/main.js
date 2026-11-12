// An Electron app for tests: says what it was given, opens a window, and ends
// when that closes. A second start's arguments go to the first, which writes
// them next to its report.
'use strict';
const { app, BrowserWindow } = require('electron');
const fs = require('fs');

const out = process.env.ZIGSAW_HELLO_REPORT;
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    if (out) fs.writeFileSync(out + '.second', JSON.stringify(argv, null, 1));
  });
  app.whenReady().then(() => {
    if (out) {
      fs.writeFileSync(out, JSON.stringify({
        isPackaged: app.isPackaged,
        defaultApp: process.defaultApp === true,
        argv: process.argv,
        name: app.getName(),
        appPath: app.getAppPath(),
        userData: app.getPath('userData'),
        resourcesPath: process.resourcesPath,
        execPath: process.execPath,
        electron: process.versions.electron,
      }, null, 1));
    }
    if (process.argv.includes('--recent')) app.addRecentDocument(__filename);
    const window = new BrowserWindow({ width: 420, height: 160 });
    window.loadURL('data:text/html,<title>zigsaw-hello</title><p>zigsaw-hello');
  });
  app.on('window-all-closed', () => app.quit());
}
