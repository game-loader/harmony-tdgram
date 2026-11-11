import { TdObject } from './TdClient';
import { InlineButton, MsgItem, PollOptionItem, ReactionItem } from './Models';

export type NameOf = (senderId: number, isChat: boolean) => string;

export function ft(v: Object | undefined): string {
  return v ? (((v as TdObject)['text'] as string) ?? '') : '';
}

function ftEntities(v: Object | undefined): TdObject[] {
  return v ? (((v as TdObject)['entities'] as TdObject[]) ?? []) : [];
}

// Path of a fully downloaded (or locally uploaded) file, else ''.
export function localPath(file: TdObject | undefined): string {
  if (!file) {
    return '';
  }
  const local = file['local'] as TdObject;
  return local && local['is_downloading_completed'] ? local['path'] as string : '';
}

function setFile(item: MsgItem, file: TdObject | undefined): void {
  if (!file) {
    return;
  }
  item.fileId = file['id'] as number;
  const remote = file['remote'] as TdObject | undefined;
  item.fileUid = remote ? ((remote['unique_id'] as string) ?? '') : '';
  item.filePath = localPath(file);
  item.fileSize = (file['size'] as number) || (file['expected_size'] as number) || 0;
}

function setThumb(item: MsgItem, thumb: TdObject | undefined, mini: TdObject | undefined): void {
  if (thumb) {
    const f = thumb['file'] as TdObject;
    item.thumbFileId = f['id'] as number;
    item.thumbPath = localPath(f);
    item.thumbIsVideo = (thumb['format'] as TdObject)['@type'] === 'thumbnailFormatMpeg4';
  }
  if (mini) {
    item.minithumb = (mini['data'] as string) ?? '';
  }
}

function setCaption(item: MsgItem, content: TdObject, key: string = 'caption'): void {
  item.text = ft(content[key]);
  item.entities = ftEntities(content[key]);
}

function senderOf(s: TdObject | undefined): number {
  if (!s) {
    return 0;
  }
  return s['@type'] === 'messageSenderUser' ? s['user_id'] as number : s['chat_id'] as number;
}
export function fillContent(item: MsgItem, content: TdObject, nameOf: NameOf): void {
  item.text = '';
  item.entities = [];
  item.fileId = 0;
  item.fileUid = '';
  item.thumbFileId = 0;
  item.thumbPath = '';
  item.minithumb = '';
  item.linkUrl = '';
  const type = content['@type'] as string;
  switch (type) {
    case 'messageText':
      item.kind = 'text';
      item.text = ft(content['text']);
      item.entities = ftEntities(content['text']);
      fillLinkPreview(item, content['link_preview'] as TdObject | undefined);
      break;
    case 'messagePhoto': {
      item.kind = 'photo';
      setCaption(item, content);
      item.hasSpoiler = content['has_spoiler'] as boolean;
      const photo = content['photo'] as TdObject;
      const sizes = (photo['sizes'] as TdObject[]) ?? [];
      // Largest size up to ~1280px; TDLib orders sizes ascending.
      let best: TdObject | undefined = undefined;
      for (const s of sizes) {
        if (!best || (s['width'] as number) <= 1280) {
          best = s;
        }
      }
      if (best) {
        setFile(item, best['photo'] as TdObject);
        item.width = best['width'] as number;
        item.height = best['height'] as number;
      }
      setThumb(item, undefined, photo['minithumbnail'] as TdObject | undefined);
      // A small rendition is shown first, and in media grids.
      const small = sizes.find((s: TdObject) => (s['width'] as number) >= 200);
      if (small && small !== best) {
        const f = small['photo'] as TdObject;
        item.thumbFileId = f['id'] as number;
        item.thumbPath = localPath(f);
        item.thumbIsVideo = false;
      }
      break;
    }
    case 'messageVideo': {
      item.kind = 'video';
      setCaption(item, content);
      item.hasSpoiler = content['has_spoiler'] as boolean;
      const v = content['video'] as TdObject;
      setFile(item, v['video'] as TdObject);
      item.width = v['width'] as number;
      item.height = v['height'] as number;
      item.duration = v['duration'] as number;
      item.fileName = v['file_name'] as string;
      item.mime = v['mime_type'] as string;
      setThumb(item, v['thumbnail'] as TdObject | undefined, v['minithumbnail'] as TdObject | undefined);
      break;
    }
    case 'messageAnimation': {
      item.kind = 'animation';
      setCaption(item, content);
      const a = content['animation'] as TdObject;
      setFile(item, a['animation'] as TdObject);
      item.width = a['width'] as number;
      item.height = a['height'] as number;
      item.mime = a['mime_type'] as string;
      setThumb(item, a['thumbnail'] as TdObject | undefined, a['minithumbnail'] as TdObject | undefined);
      break;
    }
    case 'messageVideoNote': {
      item.kind = 'videoNote';
      const v = content['video_note'] as TdObject;
      setFile(item, v['video'] as TdObject);
      item.width = v['length'] as number;
      item.height = item.width;
      item.duration = v['duration'] as number;
      setThumb(item, v['thumbnail'] as TdObject | undefined, v['minithumbnail'] as TdObject | undefined);
      item.recognized = speechText(v['speech_recognition_result'] as TdObject | undefined);
      break;
    }
    case 'messageVoiceNote': {
      item.kind = 'voice';
      setCaption(item, content);
      const v = content['voice_note'] as TdObject;
      setFile(item, v['voice'] as TdObject);
      item.duration = v['duration'] as number;
      item.waveform = (v['waveform'] as string) ?? '';
      item.mime = v['mime_type'] as string;
      item.listened = content['is_listened'] as boolean;
      item.recognized = speechText(v['speech_recognition_result'] as TdObject | undefined);
      break;
    }
    case 'messageAudio': {
      item.kind = 'audio';
      setCaption(item, content);
      const a = content['audio'] as TdObject;
      setFile(item, a['audio'] as TdObject);
      item.duration = a['duration'] as number;
      item.title = (a['title'] as string) || (a['file_name'] as string);
      item.performer = a['performer'] as string;
      item.fileName = a['file_name'] as string;
      item.mime = a['mime_type'] as string;
      setThumb(item, a['album_cover_thumbnail'] as TdObject | undefined,
        a['album_cover_minithumbnail'] as TdObject | undefined);
      break;
    }
    case 'messageDocument': {
      item.kind = 'document';
      setCaption(item, content);
      const d = content['document'] as TdObject;
      setFile(item, d['document'] as TdObject);
      item.fileName = d['file_name'] as string;
      item.mime = d['mime_type'] as string;
      setThumb(item, d['thumbnail'] as TdObject | undefined, d['minithumbnail'] as TdObject | undefined);
      break;
    }
    case 'messageSticker': {
      item.kind = 'sticker';
      fillSticker(item, content['sticker'] as TdObject);
      break;
    }
    case 'messagePoll': {
      item.kind = 'poll';
      const p = content['poll'] as TdObject;
      item.pollQuestion = ft(p['question']);
      item.pollTotal = p['total_voter_count'] as number;
      item.pollClosed = p['is_closed'] as boolean;
      item.pollQuiz = ((p['type'] as TdObject)['@type'] as string) === 'pollTypeQuiz';
      item.pollMultiple = (p['allows_multiple_answers'] as boolean) === true;
      item.pollOptions = ((p['options'] as TdObject[]) ?? []).map((op: TdObject) => {
        const po = new PollOptionItem();
        po.text = ft(op['text']);
        po.voters = op['voter_count'] as number;
        po.percent = op['vote_percentage'] as number;
        po.chosen = op['is_chosen'] as boolean;
        return po;
      });
      item.pollVoted = item.pollOptions.some((po: PollOptionItem) => po.chosen);
      break;
    }
    case 'messageLocation': {
      item.kind = 'location';
      const l = content['location'] as TdObject;
      item.lat = l['latitude'] as number;
      item.lon = l['longitude'] as number;
      break;
    }
    case 'messageVenue': {
      item.kind = 'location';
      const v = content['venue'] as TdObject;
      const l = v['location'] as TdObject;
      item.lat = l['latitude'] as number;
      item.lon = l['longitude'] as number;
      item.title = v['title'] as string;
      item.address = v['address'] as string;
      break;
    }
    case 'messageContact': {
      item.kind = 'contact';
      const c = content['contact'] as TdObject;
      item.title = `${c['first_name'] as string} ${c['last_name'] as string}`.trim();
      item.phone = c['phone_number'] as string;
      item.contactUserId = c['user_id'] as number;
      break;
    }
    case 'messageDice': {
      item.kind = 'dice';
      item.emoji = content['emoji'] as string;
      item.diceValue = content['value'] as number;
      break;
    }
    case 'messageCall': {
      item.kind = 'call';
      item.callVideo = content['is_video'] as boolean;
      item.duration = content['duration'] as number;
      const reason = content['discard_reason'] as TdObject | undefined;
      item.callMissed = reason !== undefined && (reason['@type'] as string) === 'callDiscardReasonMissed';
      break;
    }
    default: {
      const service = serviceText(content, item, nameOf);
      item.kind = service ? 'service' : 'unsupported';
      item.text = service || `不支持的消息类型（${type.replace('message', '')}），请在官方客户端查看`;
    }
  }
}
// Site name, title, description and (when there is one) the photo of a link preview.
function fillLinkPreview(item: MsgItem, p: TdObject | undefined): void {
  if (!p) {
    return;
  }
  item.linkUrl = (p['url'] as string) ?? '';
  item.linkSite = (p['site_name'] as string) ?? '';
  item.linkTitle = (p['title'] as string) ?? '';
  item.linkText = ft(p['description']);
  const t = p['type'] as TdObject | undefined;
  const photo = t ? t['photo'] as TdObject | undefined : undefined;
  const sizes = photo ? ((photo['sizes'] as TdObject[]) ?? []) : [];
  if (photo && sizes.length > 0) {
    // A mid-size rendition is enough for the preview card.
    let best = sizes[0];
    for (const s of sizes) {
      if ((s['width'] as number) <= 800) {
        best = s;
      }
    }
    const f = best['photo'] as TdObject;
    item.thumbFileId = f['id'] as number;
    item.thumbPath = localPath(f);
    item.thumbIsVideo = false;
    item.width = best['width'] as number;
    item.height = best['height'] as number;
    setThumb(item, undefined, photo['minithumbnail'] as TdObject | undefined);
  }
}

export function fillSticker(item: MsgItem, s: TdObject): void {
  setFile(item, s['sticker'] as TdObject);
  item.width = s['width'] as number;
  item.height = s['height'] as number;
  item.emoji = s['emoji'] as string;
  const fmt = (s['format'] as TdObject)['@type'] as string;
  item.stickerFormat = fmt === 'stickerFormatTgs' ? 'tgs' : (fmt === 'stickerFormatWebm' ? 'webm' : 'webp');
  setThumb(item, s['thumbnail'] as TdObject | undefined, undefined);
}

function speechText(r: TdObject | undefined): string {
  if (!r) {
    return '';
  }
  switch (r['@type'] as string) {
    case 'speechRecognitionResultText':
      return r['text'] as string;
    case 'speechRecognitionResultPending':
      return ((r['partial_text'] as string) || '') + '…';
    default:
      return '';
  }
}

// Human-readable text for service messages (joins, title changes, pins...).
function serviceText(c: TdObject, item: MsgItem, nameOf: NameOf): string {
  const who = nameOf(item.senderId, item.senderIsChat) || '有人';
  switch (c['@type'] as string) {
    case 'messageChatAddMembers': {
      const ids = (c['member_user_ids'] as number[]) ?? [];
      if (ids.length === 1 && ids[0] === item.senderId) {
        return `${who} 加入了群组`;
      }
      return `${who} 添加了 ${ids.map((id: number) => nameOf(id, false)).join('、')}`;
    }
    case 'messageChatJoinByLink':
    case 'messageChatJoinByRequest':
      return `${who} 通过邀请链接加入了群组`;
    case 'messageChatDeleteMember': {
      const id = c['user_id'] as number;
      return id === item.senderId ? `${who} 离开了群组` : `${who} 移除了 ${nameOf(id, false)}`;
    }
    case 'messageChatChangeTitle':
      return `${who} 将群名改为“${c['title'] as string}”`;
    case 'messageChatChangePhoto':
      return `${who} 更换了群头像`;
    case 'messageChatDeletePhoto':
      return `${who} 删除了群头像`;
    case 'messagePinMessage':
      return `${who} 置顶了一条消息`;
    case 'messageBasicGroupChatCreate':
    case 'messageSupergroupChatCreate':
      return `${who} 创建了群组“${c['title'] as string}”`;
    case 'messageChatUpgradeTo':
    case 'messageChatUpgradeFrom':
      return '群组已升级为超级群组';
    case 'messageScreenshotTaken':
      return `${who} 截取了屏幕`;
    case 'messageContactRegistered':
      return `${who} 加入了 Telegram`;
    case 'messageChatSetMessageAutoDeleteTime': {
      const t = c['message_auto_delete_time'] as number;
      return t ? `${who} 设置消息在 ${formatTimer(t)} 后自动删除` : `${who} 关闭了消息自动删除`;
    }
    case 'messageExpiredPhoto':
      return '图片已过期';
    case 'messageExpiredVideo':
      return '视频已过期';
    case 'messageExpiredVideoNote':
      return '视频消息已过期';
    case 'messageExpiredVoiceNote':
      return '语音消息已过期';
    case 'messageCustomServiceAction':
      return c['text'] as string;
    case 'messageGameScore':
      return `${who} 得了 ${c['score'] as number} 分`;
    case 'messageForumTopicCreated':
      return `${who} 创建了话题“${c['name'] as string}”`;
    case 'messageVideoChatStarted':
      return `${who} 发起了视频聊天`;
    case 'messageVideoChatEnded':
      return `视频聊天已结束（${formatDuration(c['duration'] as number)}）`;
    case 'messageGiftedPremium':
      return `${who} 赠送了 Telegram Premium`;
    default:
      return '';
  }
}

export function formatTimer(sec: number): string {
  if (sec < 60) {
    return `${sec} 秒`;
  }
  if (sec < 3600) {
    return `${Math.round(sec / 60)} 分钟`;
  }
  if (sec < 86400) {
    return `${Math.round(sec / 3600)} 小时`;
  }
  if (sec < 86400 * 7) {
    return `${Math.round(sec / 86400)} 天`;
  }
  return `${Math.round(sec / 86400 / 7)} 周`;
}

export function formatDuration(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  const pad = (n: number): string => (n < 10 ? '0' : '') + n;
  if (s >= 3600) {
    return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`;
  }
  return `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

export function fillMessage(item: MsgItem, msg: TdObject, nameOf: NameOf): MsgItem {
  item.id = msg['id'] as number;
  item.chatId = msg['chat_id'] as number;
  item.outgoing = msg['is_outgoing'] as boolean;
  const sender = msg['sender_id'] as TdObject | undefined;
  item.senderId = senderOf(sender);
  item.senderIsChat = sender !== undefined && sender['@type'] === 'messageSenderChat';
  item.date = msg['date'] as number;
  item.editDate = msg['edit_date'] as number;
  const sending = msg['sending_state'] as TdObject | undefined;
  item.pending = sending !== undefined && sending['@type'] === 'messageSendingStatePending';
  item.failed = sending !== undefined && sending['@type'] === 'messageSendingStateFailed';
  item.canRetry = item.failed && (sending!['can_retry'] as boolean) === true;
  item.isChannelPost = (msg['is_channel_post'] as boolean) === true;
  const reply = msg['reply_to'] as TdObject | undefined;
  item.replyToId = reply && reply['@type'] === 'messageReplyToMessage' ? reply['message_id'] as number : 0;
  item.selfDestructIn = (msg['self_destruct_in'] as number) ?? 0;
  const sdt = msg['self_destruct_type'] as TdObject | undefined;
  item.selfDestructTime = sdt && sdt['@type'] === 'messageSelfDestructTypeTimer' ?
    sdt['self_destruct_time'] as number : 0;
  item.albumId = String(msg['media_album_id'] ?? '0');
  const topic = msg['topic_id'] as TdObject | undefined;
  item.topicId = topic && topic['@type'] === 'messageTopicForum' ? topic['forum_topic_id'] as number : 0;
  item.forwardFrom = forwardName(msg['forward_info'] as TdObject | undefined, nameOf);
  fillInteraction(item, msg['interaction_info'] as TdObject | undefined);
  item.buttons = parseButtons(msg['reply_markup'] as TdObject | undefined);
  fillKeyboard(item, msg['reply_markup'] as TdObject | undefined);
  fillContent(item, msg['content'] as TdObject, nameOf);
  item.version++;
  return item;
}

export function fillInteraction(item: MsgItem, info: TdObject | undefined): void {
  item.views = info ? (info['view_count'] as number) : 0;
  const replies = info ? info['reply_info'] as TdObject | undefined : undefined;
  item.hasThread = replies !== undefined && replies !== null;
  item.replyCount = item.hasThread ? ((replies!['reply_count'] as number) ?? 0) : 0;
  item.reactions = [];
  const r = info ? info['reactions'] as TdObject | undefined : undefined;
  for (const reaction of r ? ((r['reactions'] as TdObject[]) ?? []) : []) {
    const type = reaction['type'] as TdObject;
    const ri = new ReactionItem();
    ri.emoji = type['@type'] === 'reactionTypeEmoji' ? type['emoji'] as string :
      (type['@type'] === 'reactionTypePaid' ? '⭐' : '✨');
    ri.count = reaction['total_count'] as number;
    ri.chosen = reaction['is_chosen'] as boolean;
    item.reactions.push(ri);
  }
}

function forwardName(info: TdObject | undefined, nameOf: NameOf): string {
  if (!info) {
    return '';
  }
  const origin = info['origin'] as TdObject | undefined;
  switch (origin ? origin['@type'] as string : '') {
    case 'messageOriginUser':
      return nameOf(origin!['sender_user_id'] as number, false);
    case 'messageOriginHiddenUser':
      return origin!['sender_name'] as string;
    case 'messageOriginChat':
      return nameOf(origin!['sender_chat_id'] as number, true);
    case 'messageOriginChannel':
      return nameOf(origin!['chat_id'] as number, true);
    default:
      return '未知来源';
  }
}

function fillKeyboard(item: MsgItem, markup: TdObject | undefined): void {
  item.keyboard = [];
  item.keyboardOneTime = false;
  if (!markup || markup['@type'] !== 'replyMarkupShowKeyboard') {
    return;
  }
  item.keyboardOneTime = (markup['one_time'] as boolean) === true;
  item.keyboard = ((markup['rows'] as TdObject[][]) ?? []).map((row: TdObject[]) =>
    row.map((b: TdObject) => b['text'] as string));
}

function parseButtons(markup: TdObject | undefined): InlineButton[][] {
  if (!markup || markup['@type'] !== 'replyMarkupInlineKeyboard') {
    return [];
  }
  return ((markup['rows'] as TdObject[][]) ?? []).map((row: TdObject[]) => row.map((b: TdObject) => {
    const btn = new InlineButton();
    btn.text = b['text'] as string;
    const t = b['type'] as TdObject;
    if (t['@type'] === 'inlineKeyboardButtonTypeUrl' || t['@type'] === 'inlineKeyboardButtonTypeLoginUrl') {
      btn.url = t['url'] as string;
    } else if (t['@type'] === 'inlineKeyboardButtonTypeCallback') {
      btn.data = t['data'] as string;
    }
    return btn;
  }));
}

// Short single-line description used in the chat list, replies and notifications.
export function summary(m: MsgItem): string {
  const cap = m.text ? ` ${m.text}` : '';
  switch (m.kind) {
    case 'text':
    case 'service':
    case 'unsupported':
      return m.text;
    case 'photo': return `🖼 图片${cap}`;
    case 'video': return `📹 视频${cap}`;
    case 'animation': return `GIF${cap}`;
    case 'videoNote': return '⏺ 视频消息';
    case 'voice': return `🎤 语音 ${formatDuration(m.duration)}`;
    case 'audio': return `🎵 ${m.performer ? m.performer + ' - ' : ''}${m.title}`;
    case 'document': return `📎 ${m.fileName}`;
    case 'sticker': return `${m.emoji} 贴纸`;
    case 'poll': return `📊 ${m.pollQuestion}`;
    case 'location': return `📍 ${m.title || '位置'}`;
    case 'contact': return `👤 ${m.title}`;
    case 'dice': return `${m.emoji} ${m.diceValue}`;
    case 'call': return m.callMissed ? '📞 未接来电' : `📞 通话 ${formatDuration(m.duration)}`;
    default: return '';
  }
}