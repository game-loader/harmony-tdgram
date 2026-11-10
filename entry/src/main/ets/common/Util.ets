import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export function formatTime(unix: number): string {
  if (!unix) {
    return '';
  }
  const d = new Date(unix * 1000);
  const now = new Date();
  const pad = (n: number): string => (n < 10 ? '0' : '') + n;
  if (d.toDateString() === now.toDateString()) {
    return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  if (d.getFullYear() === now.getFullYear()) {
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function initials(title: string): string {
  const t = title.trim();
  return t.length > 0 ? t.substring(0, 1).toUpperCase() : '?';
}

// Stable avatar color per chat, like the official clients.
const AVATAR_COLORS: string[] = ['#E17076', '#FAA774', '#A695E7', '#7BC862', '#6EC9CB', '#65AADD', '#EE7AAE'];

export function avatarColor(id: number): string {
  return AVATAR_COLORS[Math.abs(id) % AVATAR_COLORS.length];
}

// TDLib needs a real filesystem path, but pickers return content URIs, so
// the picked file is copied into the app's cache directory first.
export function copyToCache(context: common.UIAbilityContext, uri: string, name: string): string {
  const dir = context.cacheDir + '/upload';
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir);
  }
  const safe = name.replace(/[\/\\]/g, '_');
  const dest = `${dir}/${Date.now()}_${safe}`;
  const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  try {
    fs.copyFileSync(src.fd, dest);
  } finally {
    fs.closeSync(src);
  }
  return dest;
}

export function fileNameOf(uri: string): string {
  const raw = uri.substring(uri.lastIndexOf('/') + 1);
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}
