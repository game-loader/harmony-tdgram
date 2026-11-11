import { AccountCore } from './Core';
import { o, TdObject } from './TdClient';
import { localPath } from './Parse';

// Tracks downloaded file paths and transfer progress for one account.
export class FileStore {
  private core: AccountCore;
  private paths: Map<number, string> = new Map();
  private requested: Set<number> = new Set();
  // Percent (0-100) of active downloads and uploads, by file id.
  progress: Map<number, number> = new Map();
  // Raw updateFile listeners, e.g. for streaming playback.
  private watchers: Map<number, (file: TdObject) => void> = new Map();

  constructor(core: AccountCore) {
    this.core = core;
  }

  // Local path if downloaded; otherwise starts a download and returns ''.
  // The account emits 'files' when the download completes.
  path(fileId: number, priority: number = 1): string {
    if (!fileId) {
      return '';
    }
    const p = this.paths.get(fileId);
    if (p) {
      return p;
    }
    this.download(fileId, priority);
    return '';
  }

  // Local path if downloaded; never starts a download.
  known(fileId: number, fallback: string = ''): string {
    return fallback || (fileId ? (this.paths.get(fileId) ?? '') : '');
  }

  download(fileId: number, priority: number): void {
    if (!fileId || this.requested.has(fileId)) {
      return;
    }
    this.requested.add(fileId);
    this.core.td.send(o({
      '@type': 'downloadFile', 'file_id': fileId, 'priority': priority,
      'offset': 0, 'limit': 0, 'synchronous': false
    })).then((f: TdObject) => this.onFile(f)).catch(() => {
      this.requested.delete(fileId);
    });
  }

  cancel(fileId: number): void {
    this.requested.delete(fileId);
    this.progress.delete(fileId);
    this.core.td.send(o({ '@type': 'cancelDownloadFile', 'file_id': fileId, 'only_if_pending': false }))
      .catch(() => {});
    this.core.emit('files');
  }

  watch(fileId: number, fn: (file: TdObject) => void): void {
    this.watchers.set(fileId, fn);
  }

  unwatch(fileId: number): void {
    this.watchers.delete(fileId);
  }

  isDownloading(fileId: number): boolean {
    return this.requested.has(fileId) && !this.paths.has(fileId);
  }

  onUpdate(u: TdObject): void {
    if (u['@type'] === 'updateFile') {
      this.onFile(u['file'] as TdObject);
    }
  }

  private onFile(file: TdObject): void {
    const id = file['id'] as number;
    const watcher = this.watchers.get(id);
    if (watcher) {
      watcher(file);
    }
    const path = localPath(file);
    const size = (file['size'] as number) || (file['expected_size'] as number) || 0;
    const local = file['local'] as TdObject;
    const remote = file['remote'] as TdObject;
    if (path) {
      this.paths.set(id, path);
      this.progress.delete(id);
    } else if (local && local['is_downloading_active'] && size > 0) {
      this.progress.set(id, Math.floor((local['downloaded_size'] as number) * 100 / size));
    } else if (remote && remote['is_uploading_active'] && size > 0) {
      this.progress.set(id, Math.floor((remote['uploaded_size'] as number) * 100 / size));
    } else {
      this.progress.delete(id);
    }
    this.core.emit('files');
  }
}
