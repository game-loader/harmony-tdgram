import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

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

export function formatDay(unix: number): string {
  const d = new Date(unix * 1000);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) {
    return '今天';
  }
  const y = new Date(now.getTime() - 86400000);
  if (d.toDateString() === y.toDateString()) {
    return '昨天';
  }
  return d.getFullYear() === now.getFullYear() ? `${d.getMonth() + 1}月${d.getDate()}日` :
    `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

export function lastSeen(status: Record<string, Object> | null): string {
  if (!status) {
    return '';
  }
  switch (status['@type'] as string) {
    case 'userStatusOnline': return '在线';
    case 'userStatusOffline': {
      const t = status['was_online'] as number;
      const mins = Math.floor((Date.now() / 1000 - t) / 60);
      if (mins < 1) {
        return '刚刚在线';
      }
      if (mins < 60) {
        return `${mins} 分钟前在线`;
      }
      return `最后上线 ${formatDay(t)} ${formatTime(t).includes(':') ? formatTime(t) : ''}`.trim();
    }
    case 'userStatusRecently': return '最近在线';
    case 'userStatusLastWeek': return '一周内在线';
    case 'userStatusLastMonth': return '一个月内在线';
    default: return '很久以前在线';
  }
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
  const dir = ensureDir(context.cacheDir + '/upload');
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

export function ensureDir(dir: string): string {
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  return dir;
}

export function minithumbUri(b64: string): string {
  return b64 ? `data:image/jpeg;base64,${b64}` : '';
}

// Telegram waveform: 5-bit samples packed little-endian, base64-encoded.
export function decodeWaveform(b64: string, bars: number): number[] {
  const helper = new util.Base64Helper();
  let bytes: Uint8Array;
  try {
    bytes = helper.decodeSync(b64);
  } catch (e) {
    bytes = new Uint8Array(0);
  }
  const count = Math.floor(bytes.length * 8 / 5);
  const raw: number[] = [];
  for (let i = 0; i < count; i++) {
    const bit = i * 5;
    const byte = Math.floor(bit / 8);
    const v = (bytes[byte] | ((byte + 1 < bytes.length ? bytes[byte + 1] : 0) << 8)) >> (bit % 8);
    raw.push(v & 31);
  }
  const out: number[] = [];
  for (let b = 0; b < bars; b++) {
    out.push(raw.length > 0 ? raw[Math.floor(b * raw.length / bars)] / 31 : 0.15);
  }
  return out;
}

export function fileNameOf(uri: string): string {
  const raw = uri.substring(uri.lastIndexOf('/') + 1);
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}
