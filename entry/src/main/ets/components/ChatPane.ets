import { ChatView } from './ChatView';
import { TopicList } from './TopicList';
import { Nav, Route, RouteController } from '../common/Nav';
import { Accounts } from '../td/Accounts';
import { Account } from '../td/Account';
import { TopicItem } from '../td/Models';
import { o, TdObject } from '../td/TdClient';

// An opened chat. Forum supergroups first list their topics; picking one
// shows that topic's messages, and back returns to the topic list.
@Component
export struct ChatPane {
  nav: Nav = new Nav();
  route: Route = new Route();
  onBack: () => void = (): void => {};
  @Prop showBack: boolean = true;
  @Prop active: boolean = true;
  @State forum: boolean = false;
  @State resolved: boolean = false;
  @State topics: TopicItem[] = []; // zero or one element, keyed so ChatView is recreated
  private inner: RouteController = new RouteController();
  private acc: Account = Accounts.get().active();

  aboutToAppear(): void {
    this.route.controller.back = (): boolean => this.handleBack();
    this.route.controller.jumpTo = (id: number): void => this.inner.jumpTo(id);
    const c = this.acc.chat(this.route.chatId);
    // Jumping to a specific message shows it in the whole-chat history.
    if (!c || c.type !== 'supergroup' || this.route.messageId) {
      this.resolved = true;
      return;
    }
    const known = this.acc.chats.forums.get(c.groupId);
    if (known !== undefined) {
      this.forum = known;
      this.resolved = true;
      return;
    }
    this.acc.td.send(o({ '@type': 'getSupergroup', 'supergroup_id': c.groupId })).then((sg: TdObject) => {
      this.forum = sg['is_forum'] as boolean;
      this.acc.chats.forums.set(c.groupId, this.forum);
    }).catch(() => {}).finally(() => {
      this.resolved = true;
    });
  }

  private handleBack(): boolean {
    if (this.inner.back()) {
      return true;
    }
    if (this.forum && this.topics.length > 0) {
      this.closeTopic();
      return true;
    }
    return false;
  }

  private closeTopic(): void {
    this.topics = [];
    this.inner = new RouteController();
  }

  private openProfile(): void {
    const r = this.nav.push('profile');
    r.chatId = this.route.chatId;
    this.nav.commit();
  }

  build() {
    Column() {
      if (!this.resolved) {
        LoadingProgress().width(36).height(36).margin({ top: 80 }).color($r('app.color.accent'))
      } else if (this.forum && this.topics.length === 0) {
        TopicList({
          chatId: this.route.chatId,
          showBack: this.showBack,
          onBack: (): void => this.onBack(),
          onOpenTopic: (t: TopicItem): void => { this.topics = [t]; },
          onOpenProfile: (): void => this.openProfile()
        })
      } else if (this.forum) {
        ForEach(this.topics, (t: TopicItem) => {
          ChatView({
            chatId: this.route.chatId,
            topicId: t.id,
            topicName: t.name,
            readFrom: t.lastReadInboxId,
            unreadCount: t.unread,
            nav: this.nav,
            showBack: true,
            active: this.active,
            controller: this.inner,
            onBack: (): void => this.closeTopic()
          })
        }, (t: TopicItem) => `${t.id}`)
      } else {
        ChatView({
          chatId: this.route.chatId,
          messageId: this.route.messageId,
          nav: this.nav,
          showBack: this.showBack,
          active: this.active,
          controller: this.inner,
          onBack: (): void => this.onBack()
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
