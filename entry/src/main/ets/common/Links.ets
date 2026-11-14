// Telegram links. No UI imports: unit-tested by tools/test.mjs.

// Links Telegram itself opens: tg://… and t.me, telegram.me or telegram.dog
// addresses, with or without the scheme.
export function isTelegramLink(url: string): boolean {
  const u = url.trim();
  return /^tg:/i.test(u) || /^(https?:\/\/)?(www\.)?(t\.me|telegram\.me|telegram\.dog)\//i.test(u);
}
