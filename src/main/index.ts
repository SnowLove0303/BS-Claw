import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { app, BrowserWindow } from 'electron';

const systemRoot = 'F:\\XIANGMU\\BS Claw\\System';
const runtimeRoot = join(systemRoot, '.runtime');
const userDataRoot = join(runtimeRoot, 'electron-user-data');
const logsRoot = join(runtimeRoot, 'logs');
const tempRoot = join(runtimeRoot, 'temp');

for (const path of [runtimeRoot, userDataRoot, logsRoot, tempRoot]) {
  mkdirSync(path, { recursive: true });
}

process.env.TEMP = tempRoot;
process.env.TMP = tempRoot;
app.setPath('userData', userDataRoot);
app.setPath('temp', tempRoot);
app.setAppLogsPath(logsRoot);
app.disableHardwareAcceleration();

let mainWindow: BrowserWindow | null = null;

if (!app.requestSingleInstanceLock()) {
  app.quit();
}

app.on('second-instance', () => {
  if (!mainWindow) {
    return;
  }

  if (mainWindow.isMinimized()) {
    mainWindow.restore();
  }

  mainWindow.focus();
});

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1040,
    height: 700,
    minWidth: 800,
    minHeight: 560,
    show: false,
    autoHideMenuBar: true,
    backgroundColor: '#f4f4f2',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      backgroundThrottling: true,
      devTools: false,
      spellcheck: false
    }
  });

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.once('ready-to-show', () => mainWindow?.show());
  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    void mainWindow.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'));
  }
}
