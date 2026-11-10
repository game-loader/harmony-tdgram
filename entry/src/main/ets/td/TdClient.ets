import tdbridge from 'libtdbridge.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

// A TDLib object as decoded from JSON. TDLib's schema is large and evolves
// every release, so objects stay dynamic and each consumer reads the fields
// it needs.
export type TdObject = Record<string, Object>;
export type UpdateListener = (update: TdObject) => void;

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

// Thin async wrapper over TDLib's JSON client: requests carry an @extra id
// that resolves the matching promise; everything else is an update.
export class TdClient {
  private static instance: TdClient | null = null;
  private clientId: number;
  private nextExtra: number = 1;
  private pending: Map<string, Pending> = new Map();
  private listeners: UpdateListener[] = [];

  private constructor() {
    this.clientId = tdbridge.createClient();
    tdbridge.startReceive((batch: string[]) => this.onBatch(batch));
    // Any request makes TDLib start the client and emit the first auth state.
    this.send({ '@type': 'getOption', 'name': 'version' }).catch(() => {});
  }

  static get(): TdClient {
    if (!TdClient.instance) {
      TdClient.instance = new TdClient();
    }
    return TdClient.instance;
  }

  addListener(listener: UpdateListener): void {
    this.listeners.push(listener);
  }

  removeListener(listener: UpdateListener): void {
    this.listeners = this.listeners.filter((l) => l !== listener);
  }

  send(request: TdObject): Promise<TdObject> {
    const extra = String(this.nextExtra++);
    request['@extra'] = extra;
    return new Promise<TdObject>((resolve, reject) => {
      this.pending.set(extra, { resolve: resolve, reject: reject });
      tdbridge.send(this.clientId, JSON.stringify(request));
    });
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
          continue;
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
}
