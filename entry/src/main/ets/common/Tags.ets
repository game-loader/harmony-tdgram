// Hashtag helpers. No UI imports: unit-tested by tools/test.mjs.

// '#tag' as typed or tapped -> the form to search for; '' when it is not a tag.
export function normalizeTag(raw: string): string {
  const t = raw.trim();
  const body = t.startsWith('#') || t.startsWith('$') ? t.substring(1) : t;
  if (!body || /\s/.test(body)) {
    return '';
  }
  return (t.startsWith('$') ? '$' : '#') + body;
}

// One line of `text` around the first occurrence of `needle`, at most `max`
// characters, with an ellipsis where it was cut.
export function snippetAround(text: string, needle: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  if (flat.length <= max) {
    return flat;
  }
  const at = needle ? flat.toLowerCase().indexOf(needle.toLowerCase()) : -1;
  if (at < 0 || at + needle.length <= max - 1) {
    return flat.substring(0, max - 1) + '…';
  }
  const lead = Math.max(0, Math.floor((max - needle.length) / 3));
  const from = Math.max(0, Math.min(at - lead, flat.length - (max - 1)));
  const body = flat.substring(from, from + max - 1 - (from > 0 ? 1 : 0));
  return (from > 0 ? '…' : '') + body + (from + body.length < flat.length ? '…' : '');
}
