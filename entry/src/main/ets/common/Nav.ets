// Navigation of the detail pane: a stack of routes shown to the right of the
// chat list on wide windows and over it on narrow ones. Folding or unfolding
// only changes how the same stack is laid out, so nothing is lost.
// No UI imports: unit-tested by tools/test.mjs.

export type RouteKind = 'chat' | 'profile' | 'settings' | 'contacts' | 'forward' | 'poll' | 'secretKey' | 'proxy';

// Lets the host forward the system back gesture into a route (to close a
// panel or leave selection mode before the route itself is popped).
export class RouteController {
  back: () => boolean = (): boolean => false;
  // Chats only: scrolls to a message of the chat that is already open.
  jumpTo: (messageId: number) => void = (): void => {};
}

export class Route {
  id: number = 0; // unique per pushed route, the rendering key
  kind: RouteKind = 'chat';
  chatId: number = 0;
  messageId: number = 0;
  topicId: number = 0;
  userId: number = 0;
  secretChatId: number = 0;
  title: string = '';
  controller: RouteController = new RouteController();
}

export class Nav {
  stack: Route[] = [];
  onChange: () => void = (): void => {};
  // Called when pop() finds nothing to pop: the pane was shown by a host
  // outside a stack (the login page), which then closes it.
  onEmptyPop: () => void = (): void => {};
  private seq: number = 0;

  private make(kind: RouteKind): Route {
    const r = new Route();
    r.id = ++this.seq;
    r.kind = kind;
    return r;
  }

  private changed(): void {
    this.stack = this.stack.slice();
    this.onChange();
  }

  top(): Route | undefined {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1] : undefined;
  }

  // The chat the stack started from, highlighted in the chat list.
  rootChatId(): number {
    return this.stack.length > 0 && this.stack[0].kind === 'chat' ? this.stack[0].chatId : 0;
  }

  // Chosen from the chat list: replaces whatever was open.
  openRootChat(chatId: number, messageId: number = 0): void {
    if (this.stack.length === 1 && this.stack[0].kind === 'chat' && this.stack[0].chatId === chatId && !messageId) {
      return;
    }
    const r = this.make('chat');
    r.chatId = chatId;
    r.messageId = messageId;
    this.stack = [r];
    this.changed();
  }

  // Opened from inside another route (profile, link, contact).
  openChat(chatId: number, messageId: number = 0): void {
    const n = this.stack.length;
    if (!messageId && n > 0 && this.stack[n - 1].kind === 'chat' && this.stack[n - 1].chatId === chatId) {
      return;
    }
    // Going back to the chat we came from pops instead of stacking it again.
    if (n > 1 && this.stack[n - 2].kind === 'chat' && this.stack[n - 2].chatId === chatId) {
      const target = this.stack[n - 2];
      this.stack.pop();
      this.changed();
      if (messageId) {
        target.controller.jumpTo(messageId);
      }
      return;
    }
    const r = this.make('chat');
    r.chatId = chatId;
    r.messageId = messageId;
    this.stack.push(r);
    this.changed();
  }

  // Replaces the top route with a chat (a picker that leads into a chat).
  replaceWithChat(chatId: number): void {
    this.stack.pop();
    const t = this.top();
    if (!t || t.kind !== 'chat' || t.chatId !== chatId) {
      const r = this.make('chat');
      r.chatId = chatId;
      this.stack.push(r);
    }
    this.changed();
  }

  push(kind: RouteKind): Route {
    const r = this.make(kind);
    this.stack.push(r);
    return r;
  }

  // Call after filling in the fields of a pushed route.
  commit(): void {
    this.changed();
  }

  // A page reached from the list header (settings, new chat): starts a new stack.
  openRoot(kind: RouteKind): Route {
    const r = this.make(kind);
    this.stack = [r];
    return r;
  }

  pop(): boolean {
    if (this.stack.length === 0) {
      this.onEmptyPop();
      return false;
    }
    this.stack.pop();
    this.changed();
    return true;
  }

  clear(): void {
    if (this.stack.length > 0) {
      this.stack = [];
      this.changed();
    }
  }

  // System back: the top route gets the first chance, then it is popped.
  // False when nothing is open, so the host can leave the app.
  back(): boolean {
    const t = this.top();
    if (!t) {
      return false;
    }
    if (t.controller.back()) {
      return true;
    }
    return this.pop();
  }
}
