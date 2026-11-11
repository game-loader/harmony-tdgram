import { common } from '@kit.AbilityKit';
import { TdClient } from './TdClient';

export type AccountEvent = 'auth' | 'chats' | 'messages' | 'files' | 'folders' | 'typing' | 'me' | 'pinned' | 'topics';
export type AccountListener = (event: AccountEvent) => void;

// What the per-account sub-stores need from their account. Keeping it an
// interface avoids import cycles between Account and the stores.
export interface AccountCore {
  td: TdClient;
  context: common.UIAbilityContext;
  myUserId: number;
  emit(event: AccountEvent): void;
}
