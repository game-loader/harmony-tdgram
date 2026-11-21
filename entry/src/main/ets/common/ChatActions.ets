import { promptAction } from '@kit.ArkUI';
import { Account } from '../td/Account';
import { ChatItem } from '../td/Models';
import { Nav } from './Nav';
import { dialog, toast } from './Ui';

// Deleting a chat from the list, after asking. Groups and channels are left
// (see confirmLeave); private chats can be deleted for both sides, a bot can
// be stopped at the same time. The chat's open routes close afterwards.
export function confirmDelete(acc: Account, nav: Nav, c: ChatItem): void {
  if (c.type !== 'private' && c.type !== 'secret') {
    confirmLeave(acc, nav, c);
    return;
  }
  const u = c.userId ? acc.user(c.userId) : undefined;
  const isBot = u !== undefined && u.isBot;
  const self = c.userId === acc.myUserId;
  const buttons: promptAction.Button[] = [{ text: '取消', color: '#888888' }, { text: '删除', color: '#E84026' }];
  if (c.type === 'private' && !self) {
    buttons.push(isBot ? { text: '删除并停止机器人', color: '#E84026' } : { text: '同时为对方删除', color: '#E84026' });
  }
  dialog({
    title: c.type === 'secret' ? `删除与“${c.title}”的私密聊天？` : `删除与“${c.title}”的聊天？`,
    message: c.type === 'secret' ? '私密聊天会被关闭，双方的消息都会删除。' : undefined,
    buttons: buttons
  }).then((r: promptAction.ShowDialogSuccessResponse) => {
    if (r.index < 1) {
      return;
    }
    const stopBot = isBot && r.index === 2;
    acc.deleteChat(c, r.index === 2 && !isBot).then(() => {
      nav.closeChat(c.id);
      toast('已删除');
      if (stopBot) {
        acc.setBlocked(c.userId, true).catch(() => {});
      }
    }).catch((e: Error) => toast(e.message));
  }).catch(() => {});
}

// Leaving a group or channel, after asking. Its creator can also delete it
// for everyone. The chat's routes close afterwards.
export function confirmLeave(acc: Account, nav: Nav, c: ChatItem): void {
  const what = c.type === 'channel' ? '频道' : '群组';
  acc.canDeleteForAll(c).then((canDelete: boolean) => {
    const buttons: promptAction.Button[] = [{ text: '取消', color: '#888888' }, { text: '退出', color: '#E84026' }];
    if (canDelete) {
      buttons.push({ text: `删除${what}`, color: '#E84026' });
    }
    return dialog({
      title: `退出${what}“${c.title}”？`,
      message: canDelete ? `删除${what}会移除所有成员和消息，无法恢复。` : undefined,
      buttons: buttons
    });
  }).then((r: promptAction.ShowDialogSuccessResponse) => {
    if (r.index < 1) {
      return;
    }
    const p = r.index === 2 ? acc.deleteForAll(c) : acc.deleteChat(c, false);
    p.then(() => {
      nav.closeChat(c.id);
      toast(r.index === 2 ? `已删除${what}` : `已退出${what}`);
    }).catch((e: Error) => toast(e.message));
  }).catch(() => {});
}
