const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
let seq = 0, installed = true, accepted = true, pendingSend, packingGate, sent = [], files = new Set(), removed = 0, released = 0, writes = 0;
class Base { checkArgs() { return true; } }
class Auth extends Base {} class Share extends Base {} class Transfer extends Base {}
const wx = { BaseReq: Base, SendAuthReq: Auth, SendAuthResp: class {}, SendMessageToWXReq: Share, SendMessageToWXResp: class {}, OpenBusinessViewReq: Transfer, OpenBusinessViewResp: class {}, WXImageObject: class {}, WXWebpageObject: class {}, WXMediaMessage: class {}, Log: { setLogImpl() {} },
WXAPIFactory: { createWXAPI: () => ({ setPayReportEnabled() {}, handleWant: () => true, isWXAppInstalled: () => installed, sendReq: async (_ctx, req) => { sent.push(req); if (accepted === 'delay') return new Promise(resolve => { pendingSend = resolve; }); return accepted; } }) } };
Share.WXSceneTimeline = 1; Share.WXSceneSession = 0;
const sdk = {
 '@tencent/wechat_open_sdk': wx, '@kit.AbilityKit': {},
 '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ generateRandomSync: n => ({ data: Buffer.alloc(n, ++seq) }) }) } },
 '@kit.ArkTS': { util: { generateRandomUUID: () => `tx-${++seq}`, Base64Helper: class { encodeToStringSync(x) { return Buffer.from(x).toString('base64'); } decodeSync(x) { if (x === 'bad') throw Error('bad'); return new Uint8Array(Buffer.from(x, 'base64')); } } }, url: { URL } },
 '@kit.CoreFileKit': { fileUri: { getUriFromPath: x => x }, fileIo: { OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 }, open: async p => { files.add(p); return { fd: p }; }, close: async () => {}, write: async (_fd, bytes) => { writes++; return Math.min(2, bytes.byteLength); }, unlink: async p => { files.delete(p); removed++; } } },
 '@kit.ImageKit': { image: { createImageSource: () => ({ getImageInfo: async () => ({ mimeType: 'image/png', size: { width: 800, height: 600 } }), createPixelMap: async () => ({ release: async () => released++ }), release: async () => released++ }), createImagePacker: () => ({ packing: async () => { if (packingGate) await packingGate; return new ArrayBuffer(8); }, release: async () => released++ }) } }
};
const source = fs.readFileSync(`${__dirname}/../ohos/wechat-native/src/main/ets/WechatClient.ets`, 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const mod = { exports: {} }; vm.runInNewContext(output, { exports: mod.exports, require: key => sdk[key], Uint8Array, ArrayBuffer, Set, console });
const { WechatClient } = mod.exports;
function response(Type, req, extra = {}) { return Object.assign(new Type(), { transaction: req.transaction, errCode: 0 }, extra); }
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
(async () => {
 const client = WechatClient.configure('host-app-id', { cacheDir: '/tmp' });
 assert.equal(WechatClient.configure('host-app-id', {}), client);
 assert.throws(() => WechatClient.configure('other-app-id', {}));
 const receipts = []; client.addListener(r => receipts.push(r));
 assert.equal(await client.authorize('oauth-1'), 'requested');
 const req = sent.at(-1); assert(req.state.length >= 40);
 assert.equal(await client.authorize('oauth-busy'), 'busy');
 client.onResp(response(wx.SendAuthResp, req, { state: 'forged', code: 'secret' }));
 client.onResp(response(wx.SendAuthResp, req, { state: undefined, errCode: -2 }));
 assert.equal(receipts.length, 0);
 client.onResp(response(wx.SendAuthResp, req, { state: req.state, code: 'code' }));
 assert.equal(receipts.length, 1); assert.equal(receipts[0].authorizationCode, 'code');
 client.onResp(response(wx.SendAuthResp, req, { state: req.state, code: 'code' })); assert.equal(receipts.length, 1);
 assert.equal(await client.authorize('oauth-1'), 'invalid_content');
 assert.equal(await client.authorize('oauth-2'), 'requested'); const next = sent.at(-1);
 client.onResp(response(wx.SendAuthResp, req, { state: req.state, code: 'late' })); assert.equal(receipts.length, 1);
 client.cancel('oauth-2');
 assert.equal(await client.authorize('oauth-3'), 'requested'); const third = sent.at(-1);
 client.onResp(response(wx.SendAuthResp, next, { state: next.state, code: 'late' })); assert.equal(receipts.length, 1);
 client.onResp(response(wx.SendAuthResp, third, { state: third.state, code: '' })); assert.equal(receipts.at(-1).errorCode, -1);
 accepted = 'delay'; const slow = client.authorize('slow'); const slowReq = sent.at(-1); client.cancel('slow');
 accepted = true; assert.equal(await client.authorize('new'), 'requested'); const newReq = sent.at(-1);
 pendingSend(false); assert.equal(await slow, 'cancelled');
 client.onResp(response(wx.SendAuthResp, newReq, { state: newReq.state, code: 'new-code' })); assert.equal(receipts.at(-1).requestId, 'new');
 client.onResp(response(wx.SendAuthResp, slowReq, { state: slowReq.state, code: 'late' })); assert.equal(receipts.at(-1).requestId, 'new');
 assert.equal(await client.shareWebPage('url-invalid', 'javascript:alert(1)', '', '', 'aA==', 'session'), 'invalid_content');
 assert.equal(await client.shareWebPage('url-creds', 'https://user:pw@example.com', '', '', 'aA==', 'session'), 'invalid_content');
 assert.equal(await client.shareImage('image-invalid', 'bad', 'session'), 'invalid_content');
 assert.equal(await client.shareImage('scene-invalid', 'aA==', 'other'), 'invalid_content');
 assert.equal(await client.openMerchantTransfer('transfer', 'merchant', 'app', ' p=+&\u4e2d '), 'requested');
 const transfer = sent.at(-1); assert.equal(transfer.businessType, 'requestMerchantTransfer');
 assert(transfer.query.endsWith('package=%20p%3D%2B%26%E4%B8%AD%20'));
 client.onResp(response(wx.OpenBusinessViewResp, transfer, { businessType: 'requestMerchantTransfer', extMsg: '{"result":"success"}' }));
 assert.equal(receipts.at(-1).pageResult, 'success'); assert(!('paid' in receipts.at(-1)));
 assert.equal(await client.shareImage('image', 'aGVsbG8=', 'timeline'), 'requested');
 assert.equal(files.size, 1); assert.equal(writes, 3);
 const img = sent.at(-1); assert.equal(img.scene, 1);
 client.onResp(response(wx.SendMessageToWXResp, img)); await flush(); assert.equal(files.size, 0);
 const before = removed; accepted = false;
 assert.equal(await client.shareImage('image-rejected', 'aGVsbG8=', 'session'), 'failed'); await flush(); assert(removed > before); assert.equal(files.size, 0);
 accepted = true; let finish; packingGate = new Promise(r => finish = r);
 const cancelPreparing = client.shareImage('image-cancel', 'aGVsbG8=', 'session'); await flush(); client.cancel('image-cancel'); finish(); assert.equal(await cancelPreparing, 'cancelled'); packingGate = null; assert.equal(files.size, 0);
 installed = false; assert.equal(await client.authorize('no-wechat'), 'not_installed');
 assert(released >= 9);
 console.log('OHOS OAuth state, transaction, duplicate/late callbacks, concurrency, raw transfer encoding, URL validation and temporary file lifecycle passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
