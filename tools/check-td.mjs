#!/usr/bin/env node
// Checks every TDLib request and type name written in the ArkTS sources
// against TDLib's schema (td_api.tl). TDLib objects are plain JSON here, so a
// misspelled '@type' or field name compiles fine and only fails at runtime.
//
//   node tools/check-td.mjs [--schema path/to/td_api.tl]
//
// The schema comes from the TDLib checkout that libtdjson.so was built from:
// --schema, $TD_API_TL, or the usual build locations.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function findSchema() {
  const i = process.argv.indexOf('--schema');
  const candidates = [
    i >= 0 ? process.argv[i + 1] : '', process.env.TD_API_TL ?? '',
    path.join(root, 'build-td/td/td/generate/scheme/td_api.tl'),
    path.join(root, '../td/td/generate/scheme/td_api.tl'),
    path.join(os.homedir(), 'tg-build/td/td/generate/scheme/td_api.tl')
  ];
  return candidates.find((p) => p && fs.existsSync(p));
}

export function sdkLoaderDir() {
  let sdk = process.env.OHOS_BASE_SDK_HOME ?? '';
  const props = path.join(root, 'local.properties');
  if (!sdk && fs.existsSync(props)) {
    sdk = (/^sdk\.dir=(.+)$/m.exec(fs.readFileSync(props, 'utf8')) ?? [])[1] ?? '';
  }
  const api = fs.readdirSync(sdk).filter((d) => /^\d+$/.test(d)).sort((a, b) => b - a)[0];
  return path.join(sdk, api, 'ets/build-tools/ets-loader');
}

// name -> { fields: Map<field, type>, result: class name, fn: boolean }
export function parseSchema(file) {
  const types = new Map();
  let fn = false;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (line.startsWith('---functions---')) {
      fn = true;
      continue;
    }
    const m = /^([a-zA-Z][A-Za-z0-9_]*)((?: [a-z][a-z0-9_]*:[A-Za-z0-9_<>]+)*) = ([A-Za-z0-9_]+);$/.exec(line);
    if (!m) {
      continue;
    }
    const fields = new Map();
    for (const f of m[2].trim().split(' ').filter((s) => s)) {
      const k = f.indexOf(':');
      fields.set(f.slice(0, k), f.slice(k + 1));
    }
    types.set(m[1], { fields, result: m[3], fn });
  }
  return types;
}

function main() {
  const schemaFile = findSchema();
  if (!schemaFile) {
    console.error('td_api.tl not found; pass --schema or set TD_API_TL');
    process.exit(2);
  }
  const loader = sdkLoaderDir();
  const require = createRequire(import.meta.url);
  const ts = require(path.join(loader, 'node_modules/typescript'));
  const etsOptions = { ets: require(path.join(loader, 'tsconfig.json')).compilerOptions.ets };
  const types = parseSchema(schemaFile);
  const allFields = new Set(['@type', '@extra', '@client_id']);
  types.forEach((t) => t.fields.forEach((_, k) => allFields.add(k)));

  const errors = [];
  let literals = 0;
  let names = 0;

  const files = [];
  const walkDir = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) {
        walkDir(p);
      } else if (e.name.endsWith('.ets')) {
        files.push(p);
      }
    }
  };
  walkDir(path.join(root, 'entry/src/main/ets'));

  for (const file of files) {
    const sf = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true,
      ts.ScriptKind.ETS, etsOptions);
    const rel = path.relative(root, file);
    const report = (node, msg) => {
      const pos = sf.getLineAndCharacterOfPosition(node.getStart());
      errors.push(`${rel}:${pos.line + 1}: ${msg}`);
    };
    const key = (p) => p.name && (ts.isStringLiteral(p.name) || ts.isIdentifier(p.name)) ? p.name.text : undefined;
    // String literals an expression can evaluate to ('a', c ? 'a' : 'b'); undefined when dynamic.
    const literalsOf = (e) => {
      if (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e)) {
        return [e.text];
      }
      if (ts.isParenthesizedExpression(e)) {
        return literalsOf(e.expression);
      }
      if (ts.isConditionalExpression(e)) {
        const a = literalsOf(e.whenTrue);
        const b = literalsOf(e.whenFalse);
        return a && b ? a.concat(b) : undefined;
      }
      return undefined;
    };
    const typeNamesOf = (obj) => {
      const p = obj.properties.find((x) => ts.isPropertyAssignment(x) && key(x) === '@type');
      return p ? literalsOf(p.initializer) : undefined;
    };
    // Object literals a value expression can be: o({...}), cond ? {...} : {...}, [{...}].
    const objectsOf = (e) => {
      if (ts.isObjectLiteralExpression(e)) {
        return [e];
      }
      if (ts.isParenthesizedExpression(e) || ts.isAsExpression(e)) {
        return objectsOf(e.expression);
      }
      if (ts.isCallExpression(e) && ts.isIdentifier(e.expression) && e.expression.text === 'o' && e.arguments.length === 1) {
        return objectsOf(e.arguments[0]);
      }
      if (ts.isConditionalExpression(e)) {
        return objectsOf(e.whenTrue).concat(objectsOf(e.whenFalse));
      }
      if (ts.isArrayLiteralExpression(e)) {
        return e.elements.flatMap((x) => objectsOf(x));
      }
      return [];
    };
    const fits = (name, declared) => {
      const elem = declared.replace(/^(vector<)+/, '').replace(/>+$/, '');
      const t = types.get(name);
      return t !== undefined && !t.fn && (elem === name || elem === t.result);
    };

    const visit = (node) => {
      if (ts.isObjectLiteralExpression(node)) {
        const candidates = typeNamesOf(node);
        if (candidates) {
          literals++;
          const known = candidates.filter((n) => types.has(n));
          for (const n of candidates) {
            if (!types.has(n)) {
              report(node, `unknown TDLib type '${n}'`);
            }
          }
          for (const p of node.properties) {
            const k = ts.isPropertyAssignment(p) ? key(p) : undefined;
            if (!k || k.startsWith('@') || known.length === 0) {
              continue;
            }
            const declared = known.map((n) => types.get(n).fields.get(k)).filter((x) => x);
            if (declared.length === 0) {
              report(p, `'${known.join("' / '")}' has no field '${k}'`);
              continue;
            }
            for (const child of objectsOf(p.initializer)) {
              for (const cn of typeNamesOf(child) ?? []) {
                if (types.has(cn) && !declared.some((d) => fits(cn, d))) {
                  report(child, `field '${k}' of '${known.join("' / '")}' expects ${declared.join(' / ')}, got '${cn}'`);
                }
              }
            }
          }
        }
      }
      // req['field'] = ... and u['field'] reads: the name must exist somewhere in the schema.
      if (ts.isElementAccessExpression(node) && ts.isStringLiteral(node.argumentExpression)) {
        const k = node.argumentExpression.text;
        if (!allFields.has(k) && !/^[A-Z]/.test(k) && /^[a-z@_][a-z0-9_@]*$/.test(k) && k.includes('_')) {
          report(node, `'${k}' is not a field of any TDLib type`);
        }
      }
      // x['@type'] === 'name' and switch (x['@type']) { case 'name': }
      const isTypeRead = (e) => e && /\[['"]@type['"]\]/.test(e.getText());
      if (ts.isBinaryExpression(node) && [ts.SyntaxKind.EqualsEqualsEqualsToken,
        ts.SyntaxKind.ExclamationEqualsEqualsToken].includes(node.operatorToken.kind)) {
        const pairs = [[node.left, node.right], [node.right, node.left]];
        for (const pair of pairs) {
          if (isTypeRead(pair[0]) && ts.isStringLiteral(pair[1])) {
            names++;
            if (!types.has(pair[1].text) && pair[1].text !== 'error') {
              report(pair[1], `unknown TDLib type '${pair[1].text}'`);
            }
          }
        }
      }
      if (ts.isSwitchStatement(node) && isTypeRead(node.expression)) {
        for (const clause of node.caseBlock.clauses) {
          if (ts.isCaseClause(clause) && ts.isStringLiteral(clause.expression)) {
            names++;
            if (!types.has(clause.expression.text) && clause.expression.text !== '') {
              report(clause.expression, `unknown TDLib type '${clause.expression.text}'`);
            }
          }
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sf);
  }

  for (const e of errors) {
    console.error(e);
  }
  console.log(`check-td: ${files.length} files, ${literals} TDLib objects, ${names} type names, ${errors.length} problem(s)`
    + `  [schema: ${types.size} types]`);
  process.exit(errors.length > 0 ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}
