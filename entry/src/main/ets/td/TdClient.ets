import tdbridge from 'libtdbridge.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

// A TDLib object as decoded from JSON. TDLib's schema is large and evolves
// every release, so objects stay dynamic and each consumer reads the fields
// it needs.
export type TdObject = Record<string, Object>;
export type UpdateListener = (update: TdObject) => void;

// Gives nested TDLib object literals an explicit type, as ArkTS requires.
export function o(obj: TdObject): TdObject {
  return obj;
}

interface Pending {
  resolve: (value: TdObject) => void;
  reject: (reason: TdError) => void;
}

export class TdError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

// td_receive() is process-wide: it returns responses and updates of every
// client, tagged with @client_id. The hub owns the single receive loop and
// routes each object to its client, which is what makes multiple accounts work.
class TdHub {
  private clients: Map<number, TdClient> = new Map();
  private started: boolean = false;

  register(client: TdClient): void {
    this.clients.set(client.id, client);
    if (!this.started) {
      this.started = true;
      tdbridge.startReceive((batch: string[]) => this.onBatch(batch));
    }
  }

  unregister(client: TdClient): void {
    this.clients.delete(client.id);
  }

  private onBatch(batch: string[]): void {
    for (const json of batch) {
      let obj: TdObject;
      try {
        obj = JSON.parse(json) as TdObject;
      } catch (e) {
        hilog.warn(0x0000, 'tdgram', 'bad json from tdlib');
        continue;
      }
      const client = this.clients.get(obj['@client_id'] as number);
      if (client) {
        client.dispatch(obj);
      }
    }
  }
}

const hub = new TdHub();
// One TDLib client, i.e. one account with its own database directory.
// Requests carry an @extra id that resolves the matching promise; everything
// else is an update for the listeners.
export class TdClient {
  readonly id: number;
  private nextExtra: number = 1;
  private pending: Map<string, Pending> = new Map();
  private listeners: UpdateListener[] = [];

  constructor() {
    this.id = tdbridge.createClient();
    hub.register(this);
  }

  // Any request makes TDLib start the client and emit the first auth state.
  start(): void {
    this.send(o({ '@type': 'getOption', 'name': 'version' })).catch(() => {});
  }

  dispose(): void {
    hub.unregister(this);
    this.listeners = [];
  }

  addListener(listener: UpdateListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: UpdateListener): void {
    this.listeners = this.listeners.filter((l: UpdateListener) => l !== listener);
  }

  send(request: TdObject): Promise<TdObject> {
    const extra = String(this.nextExtra++);
    request['@extra'] = extra;
    return new Promise<TdObject>((resolve, reject) => {
      this.pending.set(extra, { resolve: resolve, reject: reject });
      tdbridge.send(this.id, JSON.stringify(request));
    });
  }

  dispatch(obj: TdObject): void {
    const extra = obj['@extra'] as string | undefined;
    if (extra !== undefined) {
      const p = this.pending.get(extra);
      if (p) {
        this.pending.delete(extra);
        if (obj['@type'] === 'error') {
          p.reject(new TdError(obj['code'] as number, obj['message'] as string));
        } else {
          p.resolve(obj);
        }
        return;
      }
    }
    for (const l of this.listeners) {
      try {
        l(obj);
      } catch (e) {
        hilog.error(0x0000, 'tdgram', 'listener failed: %{public}s', String(e));
      }
    }
  }
}
