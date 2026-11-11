import { TdObject } from '../td/TdClient';

// A run of text with the styles of every entity covering it.
export class TextRun {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  underline: boolean = false;
  strike: boolean = false;
  code: boolean = false;
  spoiler: boolean = false;
  quote: boolean = false;
  link: string = '';      // URL to open
  mention: string = '';   // @username
  mentionUser: number = 0;
}

// TDLib entity offsets/lengths are in UTF-16 code units, which matches
// ArkTS string indexing, so slicing is direct.
export function splitRuns(text: string, entities: TdObject[]): TextRun[] {
  const cuts = new Set<number>([0, text.length]);
  for (const e of entities) {
    const off = e['offset'] as number;
    cuts.add(off);
    cuts.add(off + (e['length'] as number));
  }
  const points = Array.from(cuts).filter((x: number) => x >= 0 && x <= text.length).sort((a: number, b: number) => a - b);
  const runs: TextRun[] = [];
  for (let i = 0; i + 1 < points.length; i++) {
    const from = points[i];
    const to = points[i + 1];
    const run = new TextRun();
    run.text = text.substring(from, to);
    for (const e of entities) {
      const off = e['offset'] as number;
      if (off > from || off + (e['length'] as number) < to) {
        continue;
      }
      const t = e['type'] as TdObject;
      switch (t['@type'] as string) {
        case 'textEntityTypeBold': run.bold = true; break;
        case 'textEntityTypeItalic': run.italic = true; break;
        case 'textEntityTypeUnderline': run.underline = true; break;
        case 'textEntityTypeStrikethrough': run.strike = true; break;
        case 'textEntityTypeCode':
        case 'textEntityTypePre':
        case 'textEntityTypePreCode': run.code = true; break;
        case 'textEntityTypeSpoiler': run.spoiler = true; break;
        case 'textEntityTypeBlockQuote':
        case 'textEntityTypeExpandableBlockQuote': run.quote = true; break;
        case 'textEntityTypeUrl': run.link = run.text.includes('://') ? run.text : `https://${run.text}`; break;
        case 'textEntityTypeTextUrl': run.link = t['url'] as string; break;
        case 'textEntityTypeEmailAddress': run.link = `mailto:${run.text}`; break;
        case 'textEntityTypePhoneNumber': run.link = `tel:${run.text}`; break;
        case 'textEntityTypeMention': run.mention = run.text; break;
        case 'textEntityTypeMentionName': run.mentionUser = t['user_id'] as number; break;
        case 'textEntityTypeHashtag':
        case 'textEntityTypeCashtag':
        case 'textEntityTypeBotCommand': run.mention = run.text; break;
        default: break;
      }
    }
    runs.push(run);
  }
  return runs;
}

@Component
export struct FormattedText {
  @Prop text: string = '';
  @Prop entities: TdObject[] = [];
  @Prop fontSize: number = 16;
  @Prop color: ResourceColor = $r('app.color.text_primary');
  @State revealed: boolean = false;
  onLink: (url: string) => void = () => {};
  onMention: (name: string, userId: number) => void = () => {};

  build() {
    Text() {
      ForEach(splitRuns(this.text, this.entities), (r: TextRun) => {
        Span(r.text)
          .fontSize(this.fontSize)
          .fontWeight(r.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(r.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(r.code ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(r.spoiler && !this.revealed ? '#00000000' :
            (r.link || r.mention || r.mentionUser || r.quote ? $r('app.color.link') : this.color))
          .decoration({
            type: r.underline || r.link ? TextDecorationType.Underline :
              (r.strike ? TextDecorationType.LineThrough : TextDecorationType.None),
            color: r.link ? $r('app.color.link') : this.color
          })
          .textBackgroundStyle({
            color: r.spoiler && !this.revealed ? '#99888888' : (r.code ? $r('app.color.inset') : Color.Transparent),
            radius: 3
          })
          .onClick(() => {
            if (r.spoiler && !this.revealed) {
              this.revealed = true;
            } else if (r.link) {
              this.onLink(r.link);
            } else if (r.mention || r.mentionUser) {
              this.onMention(r.mention, r.mentionUser);
            }
          })
      }, (r: TextRun, i: number) => `${i}|${r.text}`)
    }
    .copyOption(CopyOptions.LocalDevice)
    .fontSize(this.fontSize)
  }
}
