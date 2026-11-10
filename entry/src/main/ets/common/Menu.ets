import { promptAction } from '@kit.ArkUI';

type B = promptAction.Button;
type MenuButtons = [B, B?, B?, B?, B?, B?];

const PAGE = 5; // the sixth slot holds "更多…" when there are more items

function tuple(b: B[]): MenuButtons {
  switch (b.length) {
    case 1: return [b[0]];
    case 2: return [b[0], b[1]];
    case 3: return [b[0], b[1], b[2]];
    case 4: return [b[0], b[1], b[2], b[3]];
    case 5: return [b[0], b[1], b[2], b[3], b[4]];
    default: return [b[0], b[1], b[2], b[3], b[4], b[5]];
  }
}

function button(text: string): B {
  const b: B = { text: text, color: '#000000' };
  return b;
}

// Action menu over any number of labels; resolves the chosen index, or
// rejects when dismissed. The system menu holds at most six buttons, so
// longer lists are paged with a "更多…" entry.
export function pickAction(labels: string[], title?: string, offset: number = 0): Promise<number> {
  const rest = labels.length - offset;
  const pageLabels = rest > 6 ? labels.slice(offset, offset + PAGE).concat(['更多…']) : labels.slice(offset);
  const opts: promptAction.ActionMenuOptions = { buttons: tuple(pageLabels.map((t: string) => button(t))) };
  if (title) {
    opts.title = title;
  }
  return promptAction.showActionMenu(opts).then((r: promptAction.ActionMenuSuccessResponse) => {
    if (rest > 6 && r.index === PAGE) {
      return pickAction(labels, title, offset + PAGE);
    }
    return offset + r.index;
  });
}
