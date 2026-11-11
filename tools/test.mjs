#!/usr/bin/env node
// Unit tests for the UI-free ArkTS modules. They are transpiled with the
// SDK's TypeScript into a temp directory and exercised with node:test.
//
//   node tools/test.mjs
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sdkLoaderDir } from './check-td.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const ets = path.join(here, '../entry/src/main/ets');
const MODULES = ['common/Layout', 'common/Nav', 'common/ListDiff', 'common/Tags', 'common/Filter',
  'components/AlbumLayout', 'td/Models', 'td/Filters'];

const require = createRequire(import.meta.url);
const ts = require(path.join(sdkLoaderDir(), 'node_modules/typescript'));
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'tdgram-test-'));
fs.writeFileSync(path.join(out, 'package.json'), '{"type":"commonjs"}');
for (const m of MODULES) {
  const src = fs.readFileSync(path.join(ets, m + '.ets'), 'utf8');
  const js = ts.transpileModule(src, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, fileName: m + '.ts'
  }).outputText;
  fs.mkdirSync(path.join(out, path.dirname(m)), { recursive: true });
  fs.writeFileSync(path.join(out, m + '.js'), js);
}
// Stand-ins for the system kits the modules above import.
for (const kit of fs.readdirSync(path.join(here, 'tests/stubs'))) {
  const dir = path.join(out, 'node_modules', path.basename(kit, '.cjs'));
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(path.join(here, 'tests/stubs', kit), path.join(dir, 'index.js'));
}
const tests = fs.readdirSync(path.join(here, 'tests')).filter((f) => f.endsWith('.test.mjs'))
  .map((f) => path.join(here, 'tests', f));
const r = spawnSync(process.execPath, ['--test', ...tests], { stdio: 'inherit', env: { ...process.env, TDGRAM_OUT: out } });
fs.rmSync(out, { recursive: true, force: true });
process.exit(r.status ?? 1);
