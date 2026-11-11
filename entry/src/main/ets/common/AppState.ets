import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

// Cross-page hand-offs that do not fit router params.
export class ForwardRequest {
  fromChatId: number = 0;
  ids: number[] = [];
  asCopy: boolean = false;
}

export class AppState {
  static forward: ForwardRequest | null = null;
  // Media viewer input: list of items shown in a pager.
  static viewer: ViewerItem[] = [];
  static viewerIndex: number = 0;
}

export class ViewerItem {
  kind: string = 'photo'; // photo | video | animation
  path: string = '';
  caption: string = '';
  fileId: number = 0;
  name: string = '';
  size: number = 0;
  mime: string = '';
  streamUrl: string = ''; // set while a video plays from a partial download
}

export function copyText(text: string, toast: string = '已复制'): void {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setData(data).then(() => {
    promptAction.showToast({ message: toast });
  }).catch(() => {});
}
