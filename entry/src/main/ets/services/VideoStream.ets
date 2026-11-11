import tdbridge, { StreamHandle } from 'libtdbridge.so';
import { Account } from '../td/Account';
import { o, TdObject } from '../td/TdClient';

// Plays a video while TDLib downloads it. The native loopback server hands
// bytes to the player as soon as they are on disk; when the player waits at
// an offset that is not downloaded yet (MP4 index at the end, a seek), the
// download is moved there, as the official apps do.
export class VideoStream {
  private static sessions: Map<number, VideoStream> = new Map();
  private static started: boolean = false;
  readonly url: string;
  private id: number;
  private acc: Account;
  private fileId: number;
  private size: number;
  private offset: number = 0; // where TDLib is currently downloading from
  private path: string = '';
  private complete: boolean = false;
  private querying: boolean = false;
  private dirty: boolean = false;

  private constructor(acc: Account, fileId: number, size: number, h: StreamHandle) {
    this.acc = acc;
    this.fileId = fileId;
    this.size = size;
    this.id = h.id;
    this.url = h.url;
  }

  // Returns null when streaming is unavailable (unknown size, server error).
  static open(acc: Account, fileId: number, size: number, mime: string): VideoStream | null {
    if (!fileId || size <= 0) {
      return null;
    }
    if (!VideoStream.started) {
      VideoStream.started = tdbridge.streamStart((id: number, offset: number): void => {
        VideoStream.sessions.get(id)?.need(offset);
      });
      if (!VideoStream.started) {
        return null;
      }
    }
    const s = new VideoStream(acc, fileId, size, tdbridge.streamOpen(size, mime || 'video/mp4'));
    VideoStream.sessions.set(s.id, s);
    acc.files.watch(fileId, (f: TdObject): void => s.onFile(f));
    s.need(0);
    return s;
  }

  close(): void {
    VideoStream.sessions.delete(this.id);
    tdbridge.streamClose(this.id);
    this.acc.files.unwatch(this.fileId);
    if (!this.complete) {
      this.acc.files.cancel(this.fileId);
    }
  }

  private need(offset: number): void {
    if (this.complete) {
      return;
    }
    this.offset = offset;
    this.acc.td.send(o({
      '@type': 'downloadFile', 'file_id': this.fileId, 'priority': 32,
      'offset': offset, 'limit': 0, 'synchronous': false
    })).then((f: TdObject) => this.onFile(f)).catch(() => {});
  }

  private onFile(file: TdObject): void {
    const local = file['local'] as TdObject;
    if (!local) {
      return;
    }
    this.path = (local['path'] as string) || this.path;
    if (local['is_downloading_completed']) {
      this.complete = true;
      tdbridge.streamAvailable(this.id, this.path, 0, this.size);
      return;
    }
    this.queryPrefix();
  }

  // Asks TDLib how many contiguous bytes exist from the current offset.
  // Updates arrive often, so at most one query is in flight.
  private queryPrefix(): void {
    if (this.querying) {
      this.dirty = true;
      return;
    }
    if (!this.path) {
      return;
    }
    this.querying = true;
    const offset = this.offset;
    this.acc.td.send(o({ '@type': 'getFileDownloadedPrefixSize', 'file_id': this.fileId, 'offset': offset }))
      .then((r: TdObject) => {
        tdbridge.streamAvailable(this.id, this.path, offset, r['size'] as number);
      }).catch(() => {}).finally(() => {
        this.querying = false;
        if (this.dirty) {
          this.dirty = false;
          this.queryPrefix();
        }
      });
  }
}
