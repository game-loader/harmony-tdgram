import { router } from '@kit.ArkUI';
import { ChatController, ChatView } from '../components/ChatView';

interface ChatParams {
  chatId: number;
  messageId?: number;
}

// Full-screen conversation, used when a chat is opened from another page
// (profile, contacts, links). The chat list opens chats inside pages/Main.
@Entry
@Component
struct Chat {
  private chatId: number = (router.getParams() as ChatParams).chatId;
  private messageId: number = (router.getParams() as ChatParams).messageId ?? 0;
  private controller: ChatController = new ChatController();

  onBackPress(): boolean {
    return this.controller.back();
  }

  build() {
    Column() {
      ChatView({
        chatId: this.chatId,
        messageId: this.messageId,
        controller: this.controller,
        onBack: (): void => router.back(),
        onOpenChat: (id: number): void => {
          router.pushUrl({ url: 'pages/Chat', params: { chatId: id } });
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
