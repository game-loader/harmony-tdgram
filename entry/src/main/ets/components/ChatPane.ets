import { ChatController, ChatView } from './ChatView';
import { TopicList } from './TopicList';
import { Accounts } from '../td/Accounts';
import { Account } from '../td/Account';
import { o, TdObject } from '../td/TdClient';

class OpenTopic {
  id: number = 0;
  name: string = '';
}

// An opened chat. Forum supergroups first list their topics; picking one
// shows that topic's messages, and back returns to the topic list.
@Component
export struct ChatPane {
  chatId: number = 0;
  messageId: number = 0;
  showBack: boolean = true;
  controller: ChatController = new ChatController();
  onBack: () => void = (): void => {};
  onOpenChat: (chatId: number) => void = (): void => {};
  @State forum: boolean = false;
  @State resolved: boolean = false;
  @State topics: OpenTopic[] = []; // zero or one element, keyed so ChatView is recreated
  private inner: ChatController = new ChatController();
  private acc: Account = Accounts.get().active();

  aboutToAppear(): void {
    this.controller.back = (): boolean => this.handleBack();
    const c = this.acc.chat(this.chatId);
    // Jumping to a specific message shows it in the whole-chat history.
    if (!c || c.type !== 'supergroup' || this.messageId) {
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
      this.topics = [];
      return true;
    }
    return false;
  }

  private openTopic(id: number, name: string): void {
    const t = new OpenTopic();
    t.id = id;
    t.name = name;
    this.topics = [t];
  }

  build() {
    Column() {
      if (!this.resolved) {
        LoadingProgress().width(40).height(40).margin({ top: 80 })
      } else if (this.forum && this.topics.length === 0) {
        TopicList({
          chatId: this.chatId,
          showBack: this.showBack,
          onBack: (): void => this.onBack(),
          onOpenTopic: (id: number, name: string): void => this.openTopic(id, name)
        })
      } else if (this.forum) {
        ForEach(this.topics, (t: OpenTopic) => {
          ChatView({
            chatId: this.chatId,
            topicId: t.id,
            topicName: t.name,
            showBack: true,
            controller: this.inner,
            onBack: (): void => { this.topics = []; },
            onOpenChat: this.onOpenChat
          })
        }, (t: OpenTopic) => `${t.id}`)
      } else {
        ChatView({
          chatId: this.chatId,
          messageId: this.messageId,
          showBack: this.showBack,
          controller: this.inner,
          onBack: this.onBack,
          onOpenChat: this.onOpenChat
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
