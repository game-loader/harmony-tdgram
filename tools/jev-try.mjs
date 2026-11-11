#!/usr/bin/env node
// Sends sample messages to the AI classifier exactly as the app does, to
// check the request format and to pick a threshold.
//
//   JEV_KEY=sk-... node tools/jev-try.mjs [file-with-one-message-per-line]
//   (JEV_URL and JEV_MODEL override the address and the model, JEV_RAW=1 prints the reply)
//
// The key is only read from the environment; nothing is stored.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sdkLoaderDir } from './check-td.mjs';

const key = process.env.JEV_KEY;
if (!key) {
  console.error('set JEV_KEY');
  process.exit(2);
}
const url = process.env.JEV_URL || 'https://jevmodel.org/v1/systemone';
const model = process.env.JEV_MODEL || 'jev-latest';
const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const ts = require(path.join(sdkLoaderDir(), 'node_modules/typescript'));
const src = fs.readFileSync(path.join(here, '../entry/src/main/ets/common/Filter.ets'), 'utf8');
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'tdgram-jev-')), 'Filter.cjs');
fs.writeFileSync(out, ts.transpileModule(src, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, fileName: 'Filter.ts'
}).outputText);
const F = require(out);

const SAMPLES = [
  '🔥【限时福利】全网最低价机场，高速稳定不限速，注册即送 7 天试用 👉 点击下方按钮立即领取',
  '本频道由 XX 交易所赞助：新用户注册送 100U，合约手续费 5 折，戳 @xx_official 了解详情',
  '想学 Python 赚钱吗？加入我们的 VIP 群，名额有限，私聊 @someone 报名',
  '《深入理解计算机系统》第三版 中文高清 PDF，含习题答案，已上传到网盘。',
  'Rust 1.83 发布：const 泛型能力继续扩展，新增若干稳定 API，详见更新日志。',
  '明天上午十点服务器维护，预计半小时，期间机器人无法使用，抱歉。',
  '今天这集太好看了，结尾的反转完全没想到',
  'ok'
];
const file = process.argv[2];
const lines = file ? fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()) : SAMPLES;

for (let at = 0; at < lines.length; at += F.AI_BATCH) {
  const batch = lines.slice(at, at + F.AI_BATCH).map((text) => Object.assign(new F.FilterContent(), { text }));
  let status = 0;
  let body = '';
  let left = '';
  const t0 = Date.now();
  try {
    const r = await fetch(url, {
      method: 'POST', headers: { 'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: F.jevRequest(model, batch)
    });
    status = r.status;
    left = r.headers.get('x-tokens-remaining') ?? '';
    body = await r.text();
  } catch (e) {
    body = String(e.cause?.code || e.message || e);
  }
  const res = F.jevResult(status, body, batch.length);
  console.log(`-- ${batch.length} messages, ${Date.now() - t0} ms, tokens left: ${left || '?'}${res.ok ? '' : '  ERROR ' + res.error}`);
  batch.forEach((c, i) => {
    const p = res.ok ? res.p[i] : -1;
    console.log(`${p < 0 ? '  ?  ' : p.toFixed(3)}  ${F.signature(c) || '-'}  ${c.text.slice(0, 56)}`);
  });
  if (process.env.JEV_RAW) {
    console.log(body.slice(0, 600));
  }
}
fs.rmSync(path.dirname(out), { recursive: true, force: true });
