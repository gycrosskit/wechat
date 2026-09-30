const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
let seq = 0, installed = true, accepted = true, pendingSend, packingGate, sent = [], files = new Set(), removed = 0, released = 0, writes = 0;
class Base { checkArgs() { return true; } }
class Auth extends Base {} class Share extends Base {} class Transfer extends Base {}
const wx = { BaseReq: Base, SendAuthReq: Auth, SendAuthResp: class {}, SendMessageToWXReq: Share, SendMessageToWXResp: class {}, OpenBusinessViewReq: Transfer, OpenBusinessViewResp: class {}, WXImageObject: class {}, WXWebpageObject: class {}, WXMediaMessage: class {}, Log: { setLogImpl() {} },
WXAPIFactory: { createWXAPI: () => ({ setPayReportEnabled() {}, handleWant: (want, handler) => { if (!want.verified) return false; handler.onResp(want.response); return true; }, isWXAppInstalled: () => installed, sendReq: async (_ctx, req) => { sent.push(req); if (accepted === 'delay') return new Promise(resolve => { pendingSend = resolve; }); return accepted; } }) } };
Share.WXSceneTimeline = 1; Share.WXSceneSession = 0;
const sdk = {
 '@tencent/wechat_open_sdk': wx, '@kit.AbilityKit': {},
 '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ generateRandomSync: n => ({ data: Buffer.alloc(n, ++seq) }) }) } },
 '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new Uint8Array(Buffer.from(value, 'utf8')); } }, generateRandomUUID: () => `tx-${++seq}`, Base64Helper: class { encodeToStringSync(x) { return Buffer.from(x).toString('base64'); } decodeSync(x) { if (x === 'bad') throw Error('bad'); return new Uint8Array(Buffer.from(x, 'base64')); } } }, url: { URL } },
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
 const sendsBeforeRecipient = sent.length;
 assert.equal(await client.shareImage('recipient', 'aA==', 'session', 'trusted-recipient', 'trusted-sender'), 'unsupported');
 assert.equal(await client.shareImage('recipient-timeline', 'aA==', 'timeline', 'trusted-recipient'), 'invalid_content');
 assert.equal(sent.length, sendsBeforeRecipient);
 assert.equal(await client.shareWebPage('chinese', 'https://example.com', '中'.repeat(256), '文'.repeat(512), 'aA==', 'session'), 'requested');
 const chinese = sent.at(-1); assert.equal(Buffer.byteLength(chinese.message.title), 510); assert.equal(Buffer.byteLength(chinese.message.description), 1023);
 assert.equal(chinese.message.title, '中'.repeat(170)); client.onResp(response(wx.SendMessageToWXResp, chinese));
 assert.equal(await client.shareWebPage('ascii', 'https://example.com', 'a'.repeat(300), 'b'.repeat(600), 'aA==', 'session'), 'requested');
 const ascii = sent.at(-1); assert.equal(ascii.message.title.length, 256); assert.equal(ascii.message.description.length, 512); client.onResp(response(wx.SendMessageToWXResp, ascii));
 assert.equal(await client.shareImage('oversize', Buffer.alloc(25 * 1024 * 1024 + 1).toString('base64'), 'session'), 'invalid_content');
 assert.equal(await client.shareImage('image-invalid', 'bad', 'session'), 'invalid_content');
 assert.equal(await client.shareWebPage('25m', 'https://example.com', '', '', Buffer.alloc(25 * 1024 * 1024).toString('base64'), 'session'), 'requested');
 const largeThumb = sent.at(-1); client.onResp(response(wx.SendMessageToWXResp, largeThumb));
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
 // 请求进程 -> 丢失所有组件内存 -> 回跳先到 -> 可信日志恢复 -> 后挂 Kuikly 监听。
 const fresh = () => { const mod = { exports: {} }; vm.runInNewContext(output, { exports: mod.exports, require: key => sdk[key], Uint8Array, ArrayBuffer, Set, Map }); return mod.exports.WechatClient; };
 let saved = null;
 const store = { load: () => saved, save: request => { saved = request ? { ...request } : null; } };
 installed = true;
 const First = fresh(); const first = First.configure('host-app-id', { cacheDir: '/tmp' }, store);
 assert.equal(await first.authorize('cold-oauth'), 'requested'); const coldReq = sent.at(-1);
 assert.equal(saved.transaction, coldReq.transaction); assert.equal(saved.state, coldReq.state);
 const Second = fresh();
 const valid = response(wx.SendAuthResp, coldReq, { state: coldReq.state, code: 'cold-code' });
 assert.equal(Second.forwardWant({ verified: true, response: valid }), false);
 const second = Second.configure('host-app-id', { cacheDir: '/tmp' }, store);
 assert.equal(saved, null);
 const moduleSource = fs.readFileSync(`${__dirname}/../ohos/wechat-native/src/main/ets/WechatModule.ets`, 'utf8');
 const moduleOutput = ts.transpileModule(moduleSource, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
 const render = { KuiklyRenderBaseModule: class { onDestroy() {} } };
 const moduleExports = { exports: {} };
 vm.runInNewContext(moduleOutput, { exports: moduleExports.exports, require: key => key === './WechatClient' ? { WechatClient: Second } : render, Set });
 const unrelated = new moduleExports.exports.WechatModule(); const wrongPage = [];
 unrelated.call('listen', '{}', result => wrongPage.push(result)); assert.equal(wrongPage.length, 0);
 const page = new moduleExports.exports.WechatModule(); const coldReceipts = [];
 page.call('listen', JSON.stringify({ restoredRequestId: 'cold-oauth' }), result => coldReceipts.push(result));
 assert.equal(coldReceipts.length, 1); assert.equal(coldReceipts[0].requestId, 'cold-oauth');
 second.handleWant({ verified: true, response: valid }); assert.equal(coldReceipts.length, 1);
 page.onDestroy();
 const again = new moduleExports.exports.WechatModule();
 again.call('listen', JSON.stringify({ restoredRequestId: 'cold-oauth' }), result => coldReceipts.push(result));
 assert.equal(coldReceipts.length, 1);
 const Third = fresh(); const thirdClient = Third.configure('host-app-id', { cacheDir: '/tmp' }, store); const repeats = [];
 thirdClient.addListener(r => repeats.push(r)); thirdClient.handleWant({ verified: true, response: valid }); assert.equal(repeats.length, 0);
 assert.equal(await thirdClient.authorize('type-guard'), 'requested'); const typeReq = sent.at(-1);
 thirdClient.handleWant({ verified: false, response: response(wx.SendAuthResp, typeReq, { state: typeReq.state, code: 'forged' }) });
 thirdClient.handleWant({ verified: true, response: response(wx.SendMessageToWXResp, typeReq) });
 thirdClient.handleWant({ verified: true, response: response(wx.SendAuthResp, { transaction: 'unknown' }, { state: typeReq.state, code: 'code' }) });
 thirdClient.handleWant({ verified: true, response: response(wx.SendAuthResp, typeReq, { state: 'wrong', code: 'code' }) });
 assert.equal(repeats.length, 0); assert.equal(await thirdClient.authorize('busy-cold'), 'busy');
 thirdClient.cancel('type-guard'); assert.equal(saved, null);
 const Fourth = fresh(); const fourth = Fourth.configure('host-app-id', { cacheDir: '/tmp' }, store); const cancelled = [];
 fourth.addListener(r => cancelled.push(r)); fourth.handleWant({ verified: true, response: response(wx.SendAuthResp, typeReq, { state: typeReq.state, code: 'late' }) }); assert.equal(cancelled.length, 0);
 assert.equal(await fourth.openMerchantTransfer('cold-transfer', 'merchant', 'app', 'package'), 'requested'); const coldTransfer = sent.at(-1);
 const Fifth = fresh(); const fifth = Fifth.configure('host-app-id', { cacheDir: '/tmp' }, store);
 fifth.handleWant({ verified: true, response: response(wx.OpenBusinessViewResp, coldTransfer, { businessType: 'wrong', extMsg: '{"result":"success"}' }) }); assert(saved);
 fifth.handleWant({ verified: true, response: response(wx.OpenBusinessViewResp, coldTransfer, { businessType: 'requestMerchantTransfer', extMsg: '{"result":"success"}' }) });
 const transferReceipts = []; const transferListener = r => transferReceipts.push(r); fifth.addListener(transferListener); assert.equal(transferReceipts.length, 1); assert.equal(transferReceipts[0].pageResult, 'success'); assert(!('paid' in transferReceipts[0]));
 fifth.removeListener(transferListener);
 assert.equal(await fifth.authorize('buffer-cancel'), 'requested'); const bufferedReq = sent.at(-1);
 fifth.handleWant({ verified: true, response: response(wx.SendAuthResp, bufferedReq, { state: bufferedReq.state, code: 'code' }) });
 fifth.cancel('buffer-cancel'); const cancelledBuffer = []; fifth.addListener(r => cancelledBuffer.push(r)); assert.equal(cancelledBuffer.length, 0);
 // 页面销毁取消可信 pending；下一进程没有可恢复记录。
 assert.equal(await second.authorize('disposed-page'), 'requested'); const disposedReq = sent.at(-1);
 const ownedPage = new moduleExports.exports.WechatModule(); ownedPage.call('listen', JSON.stringify({ restoredRequestId: 'disposed-page' }), () => assert.fail('disposed page receipt'));
 ownedPage.onDestroy(); assert.equal(saved, null); second.handleWant({ verified: true, response: response(wx.SendAuthResp, disposedReq, { state: disposedReq.state, code: 'late' }) });
 console.log('OHOS cold process, SDK verification, trusted journal, late Kuikly listener, cancellation and replay checks passed');
 console.log('OHOS OAuth state, transaction, duplicate/late callbacks, concurrency, raw transfer encoding, URL validation and temporary file lifecycle passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
