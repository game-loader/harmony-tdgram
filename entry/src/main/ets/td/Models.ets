import { TdObject } from './TdClient';

export type MsgKind = 'text' | 'photo' | 'video' | 'animation' | 'videoNote' | 'voice' | 'audio' | 'document' |
  'sticker' | 'poll' | 'location' | 'contact' | 'dice' | 'call' | 'service' | 'unsupported';

export type ChatType = 'private' | 'secret' | 'group' | 'supergroup' | 'channel';

export class ChatPos {
  order: string = '0'; // int64 as string, compared with BigInt
  pinned: boolean = false;
}

export class ChatItem {
  id: number = 0;
  title: string = '';
  type: ChatType = 'private';
  userId: number = 0;        // private and secret chats
  secretChatId: number = 0;  // secret chats
  groupId: number = 0;       // basic group or supergroup id
  positions: Map<string, ChatPos> = new Map(); // key: list key, see listKey()
  lastText: string = '';
  lastDate: number = 0;
  lastMsgId: number = 0;
  lastOutgoing: boolean = false;
  lastReadOutboxId: number = 0;
  unread: number = 0;
  unreadMentions: number = 0;
  markedUnread: boolean = false;
  muteFor: number = 0;
  useDefaultMute: boolean = true;
  photoFileId: number = 0;
  photoPath: string = '';
  draft: string = '';
  autoDeleteTime: number = 0;
  canSend: boolean = true;
}

export class UserItem {
  id: number = 0;
  firstName: string = '';
  lastName: string = '';
  username: string = '';
  phone: string = '';
  isBot: boolean = false;
  isPremium: boolean = false;
  status: TdObject | null = null;
  photoFileId: number = 0;

  name(): string {
    const n = `${this.firstName} ${this.lastName}`.trim();
    return n || (this.username ? '@' + this.username : '已删除的账号');
  }
}

export class SecretChatItem {
  id: number = 0;
  userId: number = 0;
  state: string = 'pending'; // pending | ready | closed
  outbound: boolean = false;
  keyHash: string = ''; // base64
}

export class PollOptionItem {
  text: string = '';
  voters: number = 0;
  percent: number = 0;
  chosen: boolean = false;
}

export class ReactionItem {
  emoji: string = '';
  count: number = 0;
  chosen: boolean = false;
}

export class InlineButton {
  text: string = '';
  url: string = '';
  data: string = ''; // base64 callback data
}

export class MsgItem {
  id: number = 0;
  chatId: number = 0;
  kind: MsgKind = 'text';
  outgoing: boolean = false;
  senderId: number = 0;
  senderIsChat: boolean = false;
  date: number = 0;
  editDate: number = 0;
  text: string = '';
  entities: TdObject[] = [];
  forwardFrom: string = '';
  replyToId: number = 0;
  pending: boolean = false;
  failed: boolean = false;
  views: number = 0;
  canBeEdited: boolean = false;
  selfDestructIn: number = 0;
  selfDestructTime: number = 0;
  hasSpoiler: boolean = false;
  // Media: main file plus a preview (thumbnail file and inline minithumbnail).
  fileId: number = 0;
  filePath: string = '';
  fileSize: number = 0;
  fileName: string = '';
  mime: string = '';
  thumbFileId: number = 0;
  thumbPath: string = '';
  thumbIsVideo: boolean = false;
  minithumb: string = ''; // base64 jpeg
  width: number = 0;
  height: number = 0;
  duration: number = 0;
  // Sticker
  stickerFormat: string = ''; // webp | tgs | webm
  emoji: string = '';
  // Voice and audio
  waveform: string = ''; // base64, 5-bit packed
  listened: boolean = true;
  recognized: string = '';
  title: string = '';
  performer: string = '';
  // Poll
  pollQuestion: string = '';
  pollOptions: PollOptionItem[] = [];
  pollTotal: number = 0;
  pollClosed: boolean = false;
  pollQuiz: boolean = false;
  pollVoted: boolean = false;
  // Location, venue, contact, dice, call
  lat: number = 0;
  lon: number = 0;
  address: string = '';
  contactUserId: number = 0;
  phone: string = '';
  diceValue: number = 0;
  callVideo: boolean = false;
  callMissed: boolean = false;
  reactions: ReactionItem[] = [];
  buttons: InlineButton[][] = [];
  // Bumped on every in-place change so ForEach keys re-render the row.
  version: number = 0;
}
