import { TdObject } from './TdClient';

export class ChatItem {
  id: number = 0;
  title: string = '';
  order: string = '0'; // int64 as string, compared with BigInt
  isPinned: boolean = false;
  lastText: string = '';
  lastDate: number = 0;
  unread: number = 0;
  photoFileId: number = 0;
  photoPath: string = '';
  privateUserId: number = 0;
}

export class MsgItem {
  id: number = 0;
  chatId: number = 0;
  outgoing: boolean = false;
  senderId: number = 0;
  date: number = 0;
  text: string = '';
  // Photo: the largest size that fits the screen is downloaded.
  photoFileId: number = 0;
  photoPath: string = '';
  photoW: number = 0;
  photoH: number = 0;
  // Document
  docName: string = '';
  docSize: number = 0;
  docFileId: number = 0;
  docPath: string = '';
  replyToId: number = 0;
  pending: boolean = false;
  failed: boolean = false;
  // Bumped on every in-place change so ForEach keys re-render the row.
  version: number = 0;
}

export function senderUserId(sender: TdObject | undefined): number {
  if (sender && sender['@type'] === 'messageSenderUser') {
    return sender['user_id'] as number;
  }
  if (sender && sender['@type'] === 'messageSenderChat') {
    return sender['chat_id'] as number;
  }
  return 0;
}

export function formattedText(ft: Object | undefined): string {
  if (!ft) {
    return '';
  }
  return ((ft as TdObject)['text'] as string) ?? '';
}

// Short single-line description used in the chat list and reply previews.
export function contentSummary(content: TdObject | undefined): string {
  if (!content) {
    return '';
  }
  switch (content['@type'] as string) {
    case 'messageText':
      return formattedText(content['text']);
    case 'messagePhoto': {
      const cap = formattedText(content['caption']);
      return cap ? `[图片] ${cap}` : '[图片]';
    }
    case 'messageDocument': {
      const doc = content['document'] as TdObject;
      return `[文件] ${doc['file_name'] as string}`;
    }
    case 'messageVideo':
      return '[视频]';
    case 'messageVoiceNote':
      return '[语音]';
    case 'messageSticker':
      return `[贴纸] ${((content['sticker'] as TdObject)['emoji'] as string) ?? ''}`;
    case 'messageAnimation':
      return '[GIF]';
    case 'messageAudio':
      return '[音频]';
    case 'messageVideoNote':
      return '[视频消息]';
    case 'messagePoll':
      return '[投票]';
    case 'messageLocation':
      return '[位置]';
    case 'messageContact':
      return '[联系人]';
    case 'messageCall':
      return '[通话]';
    default:
      return '[不支持的消息]';
  }
}

export function fillMessage(item: MsgItem, msg: TdObject): MsgItem {
  item.id = msg['id'] as number;
  item.chatId = msg['chat_id'] as number;
  item.outgoing = msg['is_outgoing'] as boolean;
  item.senderId = senderUserId(msg['sender_id'] as TdObject);
  item.date = msg['date'] as number;
  const sending = msg['sending_state'] as TdObject | undefined;
  item.pending = sending !== undefined && sending['@type'] === 'messageSendingStatePending';
  item.failed = sending !== undefined && sending['@type'] === 'messageSendingStateFailed';
  const reply = msg['reply_to'] as TdObject | undefined;
  item.replyToId = reply && reply['@type'] === 'messageReplyToMessage' ? reply['message_id'] as number : 0;
  fillContent(item, msg['content'] as TdObject);
  item.version++;
  return item;
}

export function fillContent(item: MsgItem, content: TdObject): void {
  item.text = '';
  item.photoFileId = 0;
  item.docFileId = 0;
  const type = content['@type'] as string;
  if (type === 'messageText') {
    item.text = formattedText(content['text']);
  } else if (type === 'messagePhoto') {
    item.text = formattedText(content['caption']);
    const sizes = ((content['photo'] as TdObject)['sizes'] as TdObject[]) ?? [];
    // Pick the largest size up to ~1280px; TDLib orders sizes ascending.
    let best: TdObject | undefined = undefined;
    for (const s of sizes) {
      if (!best || (s['width'] as number) <= 1280) {
        best = s;
      }
    }
    if (best) {
      const file = best['photo'] as TdObject;
      item.photoFileId = file['id'] as number;
      item.photoPath = localPath(file);
      item.photoW = best['width'] as number;
      item.photoH = best['height'] as number;
    }
  } else if (type === 'messageDocument') {
    const doc = content['document'] as TdObject;
    const file = doc['document'] as TdObject;
    item.text = formattedText(content['caption']);
    item.docName = doc['file_name'] as string;
    item.docFileId = file['id'] as number;
    item.docSize = (file['size'] as number) || (file['expected_size'] as number);
    item.docPath = localPath(file);
  } else {
    item.text = contentSummary(content);
  }
}

// Path of a fully downloaded (or locally uploaded) file, else ''.
export function localPath(file: TdObject): string {
  const local = file['local'] as TdObject;
  return local && local['is_downloading_completed'] ? local['path'] as string : '';
}
