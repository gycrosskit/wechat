const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const stores = new Map();
let flushes = 0, failFlush = false;
const preferences = { getPreferencesSync(_context, { name }) {
  if (!stores.has(name)) stores.set(name, new Map());
  const values = stores.get(name);
  return { getSync: (key, fallback) => values.get(key) ?? fallback,
    putSync: (key, value) => values.set(key, value), deleteSync: key => values.delete(key),
    flushSync() { flushes++; if (failFlush) throw Error('disk unavailable'); } };
} };
const source = fs.readFileSync(`${__dirname}/../ohos/wechat-native/src/main/ets/WechatPreferencesRequestStore.ets`, 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const mod = { exports: {} };
vm.runInNewContext(output, { exports: mod.exports, require: key => {
  if (key === '@kit.ArkData') return { preferences };
  throw Error(`Unexpected runtime import: ${key}`);
} });
const { WechatPreferencesRequestStore: Store } = mod.exports;
const request = { requestId: 'request-1', transaction: 'transaction-1', kind: 'authorization', state: 'trusted-state' };
stores.set('wechat_pending_app', new Map([['pending', JSON.stringify(request)]]));
const store = new Store('app', {});
assert.deepEqual(JSON.parse(JSON.stringify(store.load())), request);
store.save({ ...request, requestId: 'request-2' });
assert.equal(flushes, 1);
assert.equal(new Store('app', {}).load().requestId, 'request-2');
assert.equal(new Store('other-app', {}).load(), null);
assert.equal(new Store('app', {}, 'old_namespace').load(), null);
failFlush = true;
assert.throws(() => store.save(request), /disk unavailable/);
assert.throws(() => store.save(null), /disk unavailable/);
failFlush = false;
store.save(null);
assert.equal(new Store('app', {}).load(), null);
assert.throws(() => new Store('', {}), /configuration missing/);
stores.get('wechat_pending_app').set('pending', '{bad JSON');
assert.throws(() => store.load(), error => error.name === 'SyntaxError');
console.log('Preferences store: legacy namespace, restart, isolation, synchronous flush failures and deletion passed');
