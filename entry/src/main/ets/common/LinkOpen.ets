import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Account, LinkTarget } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { TdError } from '../td/TdClient';
import { copyText } from './AppState';
import { isTelegramLink } from './Links';
import { Nav } from './Nav';
import { dialog, toast, Ui } from './Ui';

// Opens what a Telegram link points to. A link from another app (fromOutside)
// replaces the open routes; one tapped inside a chat stacks on top of it.
export function openLinkTarget(acc: Account, nav: Nav, t: LinkTarget, fromOutside: boolean): void {
  if (t.proxy) {
    const mgr = Accounts.get();
    mgr.settings.proxies.push(t.proxy);
    mgr.saveSettings();
    toast('代理已保存，可在“设置 > 代理”中启用');
    nav.push('proxy');
    nav.commit();
  } else if (t.invite) {
    dialog({
      title: `加入“${t.inviteTitle}”？`,
      buttons: [{ text: '取消', color: '#888888' }, { text: '加入', color: '#3A8DDE' }]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index !== 1) {
        return;
      }
      acc.joinByLink(t.invite).then((chatId: number) => {
        if (chatId) {
          openChat(nav, chatId, 0, '', fromOutside);
        } else {
          toast('已发送加入申请');
        }
      }).catch((e: TdError) => toast(e.message));
    }).catch(() => {});
  } else if (t.chatId) {
    openChat(nav, t.chatId, t.messageId, t.botStart ? t.startParam : '', fromOutside);
  } else {
    toast('无法打开链接');
  }
}

function openChat(nav: Nav, chatId: number, messageId: number, startParam: string, fromOutside: boolean): void {
  if (fromOutside) {
    nav.clear();
  }
  nav.openChat(chatId, messageId, startParam);
}

// A tapped link: Telegram links open inside the app (onTarget, when given,
// handles the result first); other links ask, then go to the browser.
export function openUrl(acc: Account, nav: Nav, url: string, onTarget?: (t: LinkTarget) => void): void {
  if (isTelegramLink(url)) {
    acc.openLink(url).then((t: LinkTarget) => {
      if (onTarget) {
        onTarget(t);
      } else {
        openLinkTarget(acc, nav, t, false);
      }
    }).catch(() => toast('无法打开链接'));
    return;
  }
  dialog({
    title: '打开链接？', message: url,
    buttons: [{ text: '复制', color: '#888888' }, { text: '打开', color: '#3A8DDE' }]
  }).then((r: promptAction.ShowDialogSuccessResponse) => {
    if (r.index === 1) {
      openExternal(url);
    } else {
      copyText(url);
    }
  }).catch(() => {});
}

// Hands a link to the system (browser, mail, phone).
export function openExternal(url: string): void {
  const ctx = Ui.context ? Ui.context.getHostContext() as common.UIAbilityContext | undefined : undefined;
  if (!ctx) {
    return;
  }
  try {
    ctx.openLink(url).catch(() => toast('没有可以打开此链接的应用'));
  } catch (e) {
    toast('没有可以打开此链接的应用');
  }
}

// A tapped @username or user mention outside a chat (a bio, a description).
export function openMention(acc: Account, nav: Nav, name: string, userId: number): void {
  if (userId) {
    nav.push('profile').userId = userId;
    nav.commit();
  } else if (name.startsWith('@')) {
    openUrl(acc, nav, `https://t.me/${name.substring(1)}`);
  } else if (name) {
    copyText(name);
  }
}
