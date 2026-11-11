import { o, TdObject } from './TdClient';

export type ProxyKind = 'socks5' | 'http' | 'mtproto';

// A proxy server the user saved. The list lives in the app's preferences;
// TDLib is only given the one that is switched on.
export class ProxyConfig {
  kind: ProxyKind = 'socks5';
  server: string = '';
  port: number = 1080;
  user: string = '';
  pass: string = '';
  secret: string = ''; // MTProto

  toTd(): TdObject {
    let type: TdObject;
    if (this.kind === 'mtproto') {
      type = o({ '@type': 'proxyTypeMtproto', 'secret': this.secret });
    } else if (this.kind === 'http') {
      type = o({ '@type': 'proxyTypeHttp', 'username': this.user, 'password': this.pass, 'http_only': false });
    } else {
      type = o({ '@type': 'proxyTypeSocks5', 'username': this.user, 'password': this.pass });
    }
    return o({ '@type': 'proxy', 'server': this.server, 'port': this.port, 'type': type });
  }

  static from(raw: ProxyConfig): ProxyConfig {
    const p = new ProxyConfig();
    p.kind = raw.kind ?? 'socks5';
    p.server = raw.server ?? '';
    p.port = raw.port ?? 1080;
    p.user = raw.user ?? '';
    p.pass = raw.pass ?? '';
    p.secret = raw.secret ?? '';
    return p;
  }

  // The proxy described by TDLib's `proxy` object (from a t.me/proxy link).
  static fromTd(raw: TdObject): ProxyConfig {
    const p = new ProxyConfig();
    const t = raw['type'] as TdObject;
    p.server = raw['server'] as string;
    p.port = raw['port'] as number;
    const kind = t['@type'] as string;
    p.kind = kind === 'proxyTypeMtproto' ? 'mtproto' : (kind === 'proxyTypeHttp' ? 'http' : 'socks5');
    p.user = (t['username'] as string) ?? '';
    p.pass = (t['password'] as string) ?? '';
    p.secret = (t['secret'] as string) ?? '';
    return p;
  }
}
