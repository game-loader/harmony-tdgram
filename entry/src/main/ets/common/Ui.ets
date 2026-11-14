import { promptAction, UIContext } from '@kit.ArkUI';

// Toasts, dialogs, menus and page changes go through the window's UIContext:
// the global promptAction and router functions are deprecated in the 7.0
// SDK. The pages set the context when they appear, EntryAbility once the
// first page is loaded.
export class Ui {
  static context: UIContext | null = null;
}

export function toast(message: string): void {
  const ui = Ui.context;
  if (!ui) {
    return;
  }
  try {
    ui.getPromptAction().showToast({ message: message });
  } catch (e) {
    // No window to show it on.
  }
}

export function dialog(options: promptAction.ShowDialogOptions): Promise<promptAction.ShowDialogSuccessResponse> {
  const ui = Ui.context;
  if (!ui) {
    return Promise.reject(new Error('no window'));
  }
  try {
    return ui.getPromptAction().showDialog(options);
  } catch (e) {
    return Promise.reject(e as Error);
  }
}

export function actionMenu(options: promptAction.ActionMenuOptions): Promise<promptAction.ActionMenuSuccessResponse> {
  const ui = Ui.context;
  if (!ui) {
    return Promise.reject(new Error('no window'));
  }
  try {
    return ui.getPromptAction().showActionMenu(options);
  } catch (e) {
    return Promise.reject(e as Error);
  }
}

export function openPage(url: string): void {
  const ui = Ui.context;
  if (!ui) {
    return;
  }
  try {
    ui.getRouter().pushUrl({ url: url }).catch(() => {});
  } catch (e) {
    // Stays on the current page.
  }
}

export function replacePage(url: string): void {
  const ui = Ui.context;
  if (!ui) {
    return;
  }
  try {
    ui.getRouter().replaceUrl({ url: url }).catch(() => {});
  } catch (e) {
    // Stays on the current page.
  }
}
