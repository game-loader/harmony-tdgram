import { common } from '@kit.AbilityKit';
import { TdClient } from './TdClient';

export type AccountEvent = 'auth' | 'chats' | 'files' | 'folders' | 'typing' | 'me' | 'topics' | 'connection';
export type AccountListener = (event: AccountEvent) => void;

// What the per-account sub-stores need from their account. Keeping it an
// interface avoids import cycles between Account and the stores.
export interface AccountCore {
  td: TdClient;
  context: common.UIAbilityContext;
  myUserId: number;
  readReceipts: boolean; // false in ghost mode: nothing is marked as read
  emit(event: AccountEvent): void;
}
