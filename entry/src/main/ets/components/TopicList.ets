import { promptAction } from '@kit.ArkUI';
import { Avatar } from './Avatar';
import { formatTime } from '../common/Util';
import { Accounts } from '../td/Accounts';
import { Account } from '../td/Account';
import { AccountEvent } from '../td/Core';
import { TopicItem } from '../td/Models';
import { TdError } from '../td/TdClient';

function hexColor(c: number): string {
  return '#' + ('000000' + c.toString(16)).slice(-6);
}

// Topics of a forum supergroup, shown before the messages of one topic,
// like the official apps. Choosing a topic opens its own message history.
@Component
export struct TopicList {
  chatId: number = 0;
  showBack: boolean = true;
  onBack: () => void = (): void => {};
  onOpenTopic: (topicId: number, name: string) => void = (): void => {};
  @State topics: TopicItem[] = [];
  @State title: string = '';
  @State photo: string = '';
  @State loading: boolean = true;
  private acc: Account = Accounts.get().active();
  private listener = (e: AccountEvent): void => {
    if (e === 'topics' || e === 'chats') {
      this.schedule();
    }
  };
  private timer: number = -1;

  aboutToAppear(): void {
    const c = this.acc.chat(this.chatId);
    this.title = c ? c.title : '';
    this.photo = c ? (c.photoPath || this.acc.files.path(c.photoFileId)) : '';
    this.acc.on(this.listener);
    this.load();
  }

  aboutToDisappear(): void {
    this.acc.off(this.listener);
    if (this.timer >= 0) {
      clearTimeout(this.timer);
    }
  }

  // Topic updates come in bursts; refetch at most every 500 ms.
  private schedule(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.load();
    }, 500);
  }

  private load(): void {
    this.acc.chats.topics(this.chatId).then((list: TopicItem[]) => {
      this.topics = list;
      this.loading = false;
    }).catch((e: TdError) => {
      this.loading = false;
      promptAction.showToast({ message: `加载话题失败：${e.message}` });
    });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        if (this.showBack) {
          Button('‹', { buttonStyle: ButtonStyleMode.TEXTUAL }).fontSize(28).onClick(() => this.onBack())
        }
        Avatar({ title: this.title, seed: this.chatId, path: this.photo, side: 38 })
        Column() {
          Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.topics.length} 个话题`).fontSize(12).fontColor('#888888')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .padding({ left: this.showBack ? 0 : 12, right: 8, top: 2, bottom: 2 })
      .width('100%')

      if (this.loading) {
        LoadingProgress().width(40).height(40).margin({ top: 40 })
      }
      List() {
        ForEach(this.topics, (t: TopicItem) => {
          ListItem() {
            Row({ space: 12 }) {
              Text(t.isGeneral ? '#' : t.name.substring(0, 1))
                .fontSize(18).fontColor(Color.White).fontWeight(FontWeight.Medium)
                .width(44).height(44).borderRadius(22).textAlign(TextAlign.Center)
                .backgroundColor(t.isGeneral ? '#8E99A4' : hexColor(t.color))
              Column({ space: 3 }) {
                Row({ space: 4 }) {
                  if (t.isClosed) {
                    Text('🔒').fontSize(12)
                  }
                  Text(t.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  if (t.lastDate) {
                    Text(formatTime(t.lastDate)).fontSize(12).fontColor('#888888')
                  }
                }
                Row({ space: 4 }) {
                  Text(t.lastText).fontSize(14).fontColor('#777777').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  if (t.unreadMentions > 0) {
                    Text('@').fontSize(12).fontColor(Color.White).width(22).height(22).borderRadius(11)
                      .textAlign(TextAlign.Center).backgroundColor('#3A8DDE')
                  }
                  if (t.unread > 0) {
                    Text(t.unread > 999 ? '999+' : String(t.unread)).fontSize(12).fontColor(Color.White)
                      .padding({ left: 7, right: 7 }).height(22).borderRadius(11).backgroundColor('#3A8DDE')
                  } else if (t.isPinned) {
                    Text('📌').fontSize(12)
                  }
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .width('100%')
            .onClick(() => this.onOpenTopic(t.id, t.name))
          }
        }, (t: TopicItem) => `${t.id}|${t.name}|${t.unread}|${t.unreadMentions}|${t.lastDate}|${t.lastText}|${t.isPinned}`)
      }
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('sys.color.ohos_id_color_list_separator'), startMargin: 70 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
  }
}
