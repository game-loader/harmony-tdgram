// Telegram links. No UI imports: unit-tested by tools/test.mjs.
import { TdObject } from '../td/TdClient';

// Links Telegram itself opens: tg://… and t.me, telegram.me or telegram.dog
// addresses, with or without the scheme.
export function isTelegramLink(url: string): boolean {
  const u = url.trim();
  return /^tg:/i.test(u) || /^(https?:\/\/)?(www\.)?(t\.me|telegram\.me|telegram\.dog)\//i.test(u);
}

// The link a message is listed under in a profile's "links" tab: its preview's
// URL, else the first link in its text.
export function firstUrl(text: string, entities: TdObject[], previewUrl: string): string {
  if (previewUrl) {
    return previewUrl;
  }
  for (const e of entities) {
    const t = e['type'] as TdObject | undefined;
    const type = t ? t['@type'] as string : '';
    if (t && type === 'textEntityTypeTextUrl') {
      return t['url'] as string;
    }
    if (type === 'textEntityTypeUrl') {
      const off = e['offset'] as number;
      const u = text.substring(off, off + (e['length'] as number));
      return u.includes('://') ? u : `https://${u}`;
    }
  }
  return '';
}
