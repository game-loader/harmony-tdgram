import { promptAction } from '@kit.ArkUI';
import { Account, LinkTarget } from '../td/Account';
import { Accounts } from '../td/Accounts';
import { TdError } from '../td/TdClient';
import { Nav } from './Nav';
import { dialog, toast } from './Ui';

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
