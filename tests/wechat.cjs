const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
let seq = 0, installed = true, accepted = true, pendingSend, packingGate, failSourceRelease = false, sent = [], files = new Set(), removed = 0, released = 0, writes = 0;
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
 '@kit.ImageKit': { image: { createImageSource: () => ({ getImageInfo: async () => ({ mimeType: 'image/png', size: { width: 800, height: 600 } }), createPixelMap: async () => ({ release: async () => released++ }), release: async () => { released++; if (failSourceRelease) throw Error('release failed'); } }), createImagePacker: () => ({ packing: async () => { if (packingGate) await packingGate; return new ArrayBuffer(8); }, release: async () => released++ }) } }
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
 const beforeOversizedUrl = sent.length;
 assert.equal(await client.shareWebPage('url-utf8-limit', 'https://example.com/' + '中'.repeat(3500), '', '', 'aA==', 'session'), 'invalid_content');
 assert.equal(sent.length, beforeOversizedUrl, '10 KiB URL limit counts UTF-8 bytes before SDK submission');
 const sendsBeforeRecipient = sent.length;
 assert.equal(await client.shareImage('recipient', 'aA==', 'session', 'trusted-recipient', 'trusted-sender'), 'unsupported');
 assert.equal(await client.shareImage('recipient-timeline', 'aA==', 'timeline', 'trusted-recipient'), 'invalid_content');
 assert.equal(sent.length, sendsBeforeRecipient);
 assert.equal(await client.shareWebPage('chinese', 'https://example.com', '中'.repeat(256), '文'.repeat(512), 'aA==', 'session'), 'requested');
 const chinese = sent.at(-1); assert.equal(Buffer.byteLength(chinese.message.title), 510); assert.equal(Buffer.byteLength(chinese.message.description), 1023);
 assert.equal(chinese.message.title, '中'.repeat(170)); client.onResp(response(wx.SendMessageToWXResp, chinese));
 assert.equal(await client.shareWebPage('ascii', 'https://example.com', 'a'.repeat(300), 'b'.repeat(600), 'aA==', 'session'), 'requested');
 const ascii = sent.at(-1); assert.equal(ascii.message.title.length, 256); assert.equal(ascii.message.description.length, 512); client.onResp(response(wx.SendMessageToWXResp, ascii));
 assert.equal(client.text('e\u0301'.repeat(300), 256, 512), 'e\u0301'.repeat(128));
 assert.equal(client.text('a😀', 2, 512), 'a');
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
 assert.equal(client.canResume('image'), false);
 assert.equal(client.cancel('image'), false); assert.equal(files.size, 1, 'accepted image URI must remain readable');
 assert.equal(await client.shareImage('image-repeat', 'aGVsbG8=', 'session'), 'requested');
 const repeatImg = sent.at(-1); assert.equal(files.size, 2);
 const beforeImageReceipts = receipts.length;
 assert.equal(await client.shareWebPage('after-image-web', 'https://example.com', '', '', 'aA==', 'session'), 'requested');
 const afterImageWeb = sent.at(-1);
 client.onResp(response(wx.SendAuthResp, img, { state: 'wrong-kind', code: 'code' })); assert.equal(files.size, 2);
 client.onResp(response(wx.SendMessageToWXResp, img)); await flush(); assert.equal(files.size, 1);
 assert.equal(receipts.length, beforeImageReceipts); assert.equal(client.canResume('after-image-web'), true);
 assert.equal(client.cancel('image'), false); assert.equal(files.size, 1, 'old image cancel cannot delete the newer image');
 client.onResp(response(wx.SendMessageToWXResp, img)); assert.equal(client.canResume('after-image-web'), true);
 client.onResp(response(wx.SendMessageToWXResp, afterImageWeb)); assert.equal(receipts.at(-1).requestId, 'after-image-web');
 assert.equal(await client.openMerchantTransfer('after-image-transfer', 'merchant', 'app', 'package'), 'requested');
 const afterImageTransfer = sent.at(-1);
 client.onResp(response(wx.SendMessageToWXResp, repeatImg)); await flush(); assert.equal(files.size, 0);
 assert.equal(client.canResume('after-image-transfer'), true);
 client.onResp(response(wx.OpenBusinessViewResp, afterImageTransfer, { businessType: 'requestMerchantTransfer' }));
 const before = removed; accepted = false;
 assert.equal(await client.shareImage('image-rejected', 'aGVsbG8=', 'session'), 'failed'); await flush(); assert(removed > before); assert.equal(files.size, 0);
 accepted = true; let finish; packingGate = new Promise(r => finish = r);
 const cancelPreparing = client.shareImage('image-cancel', 'aGVsbG8=', 'session'); await flush(); client.cancel('image-cancel'); finish(); assert.equal(await cancelPreparing, 'cancelled'); packingGate = null; assert.equal(files.size, 0);
 installed = false; assert.equal(await client.authorize('no-wechat'), 'not_installed');
 assert(released >= 9);
 // 请求进程 -> 丢失所有组件内存 -> 回跳先到 -> 可信日志恢复 -> 后挂 Kuikly 监听。
 const fresh = () => { const mod = { exports: {} }; vm.runInNewContext(output, { exports: mod.exports, require: key => sdk[key], Uint8Array, ArrayBuffer, Set, Map }); return mod.exports.WechatClient; };
 // 图片不进入可信业务日志，SDK受理后可立即开始下一笔；文件生命周期独立于业务等待。
 installed = true;
 const ImageOnly = fresh(); let imageJournalWrites = 0;
 const imageOnly = ImageOnly.configure('host-app-id', { cacheDir: '/tmp' }, { load: () => null, save: () => { imageJournalWrites++; throw Error('image must not touch journal'); } });
 assert.equal(await imageOnly.shareImage('image-no-journal', 'aGVsbG8=', 'session'), 'requested'); const noJournalReq = sent.at(-1);
 assert.equal(imageJournalWrites, 0); assert.equal(imageOnly.canResume('image-no-journal'), false);
 imageOnly.onResp(response(wx.SendMessageToWXResp, noJournalReq)); await flush(); assert.equal(files.size, 0);
 const ImageFlow = fresh(); let imageSaved = null; const imageResults = [];
 const imageFlow = ImageFlow.configure('host-app-id', { cacheDir: '/tmp' }, { load: () => imageSaved, save: value => { imageSaved = value; } });
 imageFlow.addListener(value => imageResults.push(value));
 accepted = 'delay'; const delayedImage = imageFlow.shareImage('image-delayed', 'aGVsbG8=', 'session'); await new Promise(resolve => setImmediate(resolve));
 const delayedImageReq = sent.at(-1); const delayedImageAck = pendingSend;
 assert.equal(imageSaved, null); assert.equal(files.size, 1);
 assert.equal(await imageFlow.shareImage('image-submitting-busy', 'aGVsbG8=', 'session'), 'busy');
 assert.equal(imageFlow.cancel('image-delayed'), true); await flush(); assert.equal(files.size, 1, 'in-flight SDK can still read the URI');
 accepted = true; assert.equal(await imageFlow.authorize('image-successor-auth'), 'requested'); const successorAuth = sent.at(-1);
 delayedImageAck(true); assert.equal(await delayedImage, 'cancelled'); assert.equal(files.size, 1);
 assert.equal(imageSaved.requestId, 'image-successor-auth'); assert.equal(imageFlow.canResume('image-successor-auth'), true);
 imageFlow.onResp(response(wx.SendMessageToWXResp, delayedImageReq)); await flush(); assert.equal(files.size, 0);
 assert.equal(imageSaved.requestId, 'image-successor-auth'); assert.equal(imageResults.length, 0);
 imageFlow.onResp(response(wx.SendAuthResp, successorAuth, { state: successorAuth.state, code: 'successor-code' })); assert.equal(imageResults.at(-1).requestId, 'image-successor-auth');
 // SDK回执可能早于send Promise；回执只清图片，受理返回前仍互斥。
 accepted = 'delay'; const earlyImage = imageFlow.shareImage('image-early-receipt', 'aGVsbG8=', 'session'); await new Promise(resolve => setImmediate(resolve));
 const earlyImageReq = sent.at(-1); const earlyImageAck = pendingSend;
 imageFlow.onResp(response(wx.SendMessageToWXResp, earlyImageReq)); await flush(); assert.equal(files.size, 0);
 assert.equal(await imageFlow.authorize('image-before-ack-busy'), 'busy');
 earlyImageAck(true); assert.equal(await earlyImage, 'requested'); assert.equal(imageFlow.canResume('image-early-receipt'), false);
 assert.equal(imageResults.length, 1); accepted = true;
 accepted = 'delay'; const refusedAfterCancel = imageFlow.shareImage('image-cancelled-rejected', 'aGVsbG8=', 'session'); await new Promise(resolve => setImmediate(resolve));
 const refusedImageAck = pendingSend; assert.equal(imageFlow.cancel('image-cancelled-rejected'), true);
 accepted = true; assert.equal(await imageFlow.shareImage('image-newer-file', 'aGVsbG8=', 'session'), 'requested'); const newerImageReq = sent.at(-1);
 assert.equal(files.size, 2); refusedImageAck(false); assert.equal(await refusedAfterCancel, 'cancelled'); await flush();
 assert.equal(files.size, 1); assert(files.has(newerImageReq.message.mediaObject.uri), 'old rejection cannot remove the newer file');
 imageFlow.onResp(response(wx.SendMessageToWXResp, newerImageReq)); await flush(); assert.equal(files.size, 0);
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
 const render = { KuiklyRenderBaseModule: class { onDestroy() { this.baseDestroyed = true; } } };
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
 // 实际 ArkTS Module -> Client 取消桥：失败不释放 owner，不宣告 CANCELLED。
 const CancelClient = fresh(); let cancelSaved = null, failClear = false;
 const cancelClient = CancelClient.configure('host-app-id', { cacheDir: '/tmp' }, {
  load: () => cancelSaved,
  save: value => { if (!value && failClear) throw Error('disk unavailable'); cancelSaved = value ? { ...value } : null; }
 });
 const cancelModule = { exports: {} };
 vm.runInNewContext(moduleOutput, { exports: cancelModule.exports, require: key => key === './WechatClient' ? { WechatClient: CancelClient } : render, Set });
 const cancelPage = new cancelModule.exports.WechatModule(); const cancelReceipts = [], cancelAcks = [], submissions = [];
 cancelPage.call('listen', '{}', value => cancelReceipts.push(value));
 const callCancel = id => cancelPage.call('cancel', JSON.stringify({ requestId: id }), value => cancelAcks.push(value.status));
 cancelPage.call('authorize', JSON.stringify({ requestId: 'cancel-fails-late-receipt' }), value => submissions.push(value.status)); await flush();
 const cancelReq = sent.at(-1); assert.equal(submissions.at(-1), 'requested');
 failClear = true; callCancel('cancel-fails-late-receipt'); assert.equal(cancelAcks.at(-1), 'failed');
 assert.equal(cancelSaved.requestId, 'cancel-fails-late-receipt'); assert.equal(cancelClient.canResume('cancel-fails-late-receipt'), false, 'active owner cannot be restored by another page');
 callCancel('unknown'); assert.equal(cancelAcks.at(-1), 'no_pending');
 const foreignPage = new cancelModule.exports.WechatModule(); foreignPage.call('listen', '{}', () => assert.fail('foreign receipt'));
 foreignPage.call('cancel', JSON.stringify({ requestId: 'cancel-fails-late-receipt' }), value => assert.equal(value.status, 'no_pending'));
 assert.equal(await cancelClient.authorize('still-busy'), 'busy');
 failClear = false;
 cancelClient.handleWant({ verified: true, response: response(wx.SendAuthResp, cancelReq, { state: cancelReq.state, code: 'late-but-owned' }) });
 assert.equal(cancelReceipts.length, 1); assert.equal(cancelReceipts[0].requestId, 'cancel-fails-late-receipt');
 callCancel('cancel-fails-late-receipt'); assert.equal(cancelAcks.at(-1), 'no_pending');
 cancelPage.call('authorize', JSON.stringify({ requestId: 'cancel-retry' }), value => submissions.push(value.status)); await flush();
 const retryReq = sent.at(-1); failClear = true; callCancel('cancel-retry'); assert.equal(cancelAcks.at(-1), 'failed');
 failClear = false; callCancel('cancel-retry'); assert.equal(cancelAcks.at(-1), 'cancelled'); assert.equal(cancelSaved, null);
 callCancel('cancel-retry'); assert.equal(cancelAcks.at(-1), 'no_pending');
 cancelClient.handleWant({ verified: true, response: response(wx.SendAuthResp, retryReq, { state: retryReq.state, code: 'cancelled-late' }) });
 assert.equal(cancelReceipts.length, 1);
 // 发送尚未返回时成功取消，旧 perform 不得再产生第二个 CANCELLED 或 REQUESTED。
 accepted = 'delay'; const beforeSubmit = submissions.length;
 cancelPage.call('authorize', JSON.stringify({ requestId: 'cancel-before-submit-ack' }), value => submissions.push(value.status));
 await flush(); callCancel('cancel-before-submit-ack'); assert.equal(cancelAcks.at(-1), 'cancelled');
 pendingSend(true); await flush(); assert.equal(submissions.length, beforeSubmit); accepted = true;
 failSourceRelease = true;
 cancelPage.call('image', JSON.stringify({ requestId: 'accepted-release-failure', data: 'aGVsbG8=', scene: 'session' }), value => submissions.push(value.status));
 await new Promise(resolve => setImmediate(resolve)); failSourceRelease = false;
 const releaseReq = sent.at(-1); assert.equal(submissions.at(-1), 'requested');
 assert.equal(cancelSaved, null); assert.equal(cancelClient.canResume('accepted-release-failure'), false);
 callCancel('accepted-release-failure'); assert.equal(cancelAcks.at(-1), 'no_pending');
 cancelClient.handleWant({ verified: true, response: response(wx.SendMessageToWXResp, releaseReq) });
 await flush(); assert.equal(cancelReceipts.length, 1); assert.equal(cancelSaved, null); assert.equal(files.size, 0);
 cancelPage.call('authorize', JSON.stringify({ requestId: 'destroy-clear-failure' }), value => submissions.push(value.status)); await flush();
 const destroyReq = sent.at(-1); failClear = true;
 assert.throws(() => cancelPage.onDestroy(), /disk unavailable/);
 assert.equal(cancelPage.baseDestroyed, true);
 assert.equal(cancelClient.canResume('destroy-clear-failure'), true);
 assert.equal(cancelSaved.requestId, 'destroy-clear-failure');
 failClear = false;
 const restoredPage = new cancelModule.exports.WechatModule(); const restoredReceipts = [];
 restoredPage.call('listen', JSON.stringify({ restoredRequestId: 'destroy-clear-failure' }), value => restoredReceipts.push(value));
 cancelClient.handleWant({ verified: true, response: response(wx.SendAuthResp, destroyReq, { state: destroyReq.state, code: 'restored' }) });
 assert.equal(restoredReceipts.length, 1); assert.equal(restoredReceipts[0].requestId, 'destroy-clear-failure');
 assert.equal(cancelReceipts.length, 1, 'destroyed owner cannot receive the restored receipt');
 restoredPage.onDestroy(); foreignPage.onDestroy();
 console.log('Real OHOS cancel bridge: failed clear retains owner, late receipt, unknown/foreign/completed ID, retry and late submission ack passed');

 // 独立CMP退出复核：受理与回执分离、活动页面归属、释放异常不改写SDK受理结果。
 const RegressionClient = fresh(); let regressionSaved = null, duringClear;
 const regressionClient = RegressionClient.configure('host-app-id', { cacheDir: '/tmp' }, {
   load: () => regressionSaved,
   save: value => { if (!value) duringClear?.(); regressionSaved = value ? { ...value } : null; }
 });
 const regressionModule = { exports: {} };
 vm.runInNewContext(moduleOutput, { exports: regressionModule.exports, require: key => key === './WechatClient' ? { WechatClient: RegressionClient } : render, Set });
 const makePage = () => new regressionModule.exports.WechatModule();
 const owner = makePage(), ownerReceipts = [];
 owner.call('listen', '{}', value => ownerReceipts.push(value));
 const scenarios = [
   ['authorize', {}, wx.SendAuthResp, req => ({ state: req.state, code: 'fixture-code' })],
   ['webpage', { url: 'https://example.com', title: '', description: '', thumbnail: 'aA==', scene: 'session' }, wx.SendMessageToWXResp, () => ({})],
   ['transfer', { merchantId: 'merchant', appId: 'app', packageValue: 'package' }, wx.OpenBusinessViewResp, () => ({ businessType: 'requestMerchantTransfer' })]
 ];
 for (const [method, args, Type, extra] of scenarios) {
   accepted = 'delay'; const id = 'early-receipt-' + method, submitted = [];
   owner.call(method, JSON.stringify({ ...args, requestId: id }), value => submitted.push(value.status));
   await new Promise(resolve => setImmediate(resolve));
   const req = sent.at(-1), ack = pendingSend, before = ownerReceipts.length;
   regressionClient.onResp(response(Type, req, extra(req)));
   assert.equal(ownerReceipts.length, before + 1); assert.deepEqual(submitted, []);
   owner.call(method, JSON.stringify({ ...args, requestId: id }), value => assert.equal(value.status, 'busy'));
   ack(true); await flush(); assert.deepEqual(submitted, ['requested'], method + ' must keep submit ack after early receipt');
   regressionClient.onResp(response(Type, req, extra(req))); assert.equal(ownerReceipts.length, before + 1);
 }
 accepted = true;
 owner.call('authorize', JSON.stringify({ requestId: 'active-owner' }), () => {}); await flush();
 const activeReq = sent.at(-1), intruder = makePage(), intruderReceipts = [];
 intruder.call('listen', JSON.stringify({ restoredRequestId: 'active-owner' }), value => intruderReceipts.push(value));
 intruder.call('cancel', JSON.stringify({ requestId: 'active-owner' }), value => assert.equal(value.status, 'no_pending'));
 assert.equal(regressionSaved.requestId, 'active-owner');
 const beforeActive = ownerReceipts.length;
 regressionClient.onResp(response(wx.SendAuthResp, activeReq, { state: activeReq.state, code: 'owned' }));
 assert.equal(ownerReceipts.length, beforeActive + 1); assert.deepEqual(intruderReceipts, []);
 owner.call('authorize', JSON.stringify({ requestId: 'release-reservation' }), () => {}); await flush();
 duringClear = () => assert.equal(regressionClient.canResume('release-reservation'), false, 'release must reserve owner through journal cleanup');
 owner.onDestroy(); duringClear = undefined; assert.equal(regressionSaved, null); intruder.onDestroy();
 failSourceRelease = true;
 assert.equal(await regressionClient.shareWebPage('raw-web-release-failure', 'https://example.com', '', '', 'aA==', 'session'), 'requested');
 const rawReleaseReq = sent.at(-1);
 regressionClient.onResp(response(wx.SendMessageToWXResp, rawReleaseReq));
 const releasePage = makePage(), releaseReceipts = [], releaseStatuses = [];
 releasePage.call('listen', '{}', value => releaseReceipts.push(value));
 releasePage.call('webpage', JSON.stringify({ requestId: 'module-web-release-failure', url: 'https://example.com', title: '', description: '', thumbnail: 'aA==', scene: 'session' }), value => releaseStatuses.push(value.status));
 await new Promise(resolve => setImmediate(resolve)); failSourceRelease = false;
 assert.deepEqual(releaseStatuses, ['requested']);
 const moduleReleaseReq = sent.at(-1);
 regressionClient.onResp(response(wx.SendMessageToWXResp, moduleReleaseReq)); assert.equal(releaseReceipts.length, 1);
 assert.equal(regressionSaved, null); releasePage.onDestroy();
 for (const ticks of [3, 4, 5]) {
   const abaPage = makePage(), id = 'cancel-reentry-' + ticks, oldStatuses = [], newStatuses = [];
   abaPage.call('listen', '{}', () => {});
   accepted = 'delay';
   abaPage.call('authorize', JSON.stringify({ requestId: id }), value => oldStatuses.push(value.status));
   await flush(); const ack = pendingSend;
   ack(true);
   for (let tick = 0; tick < ticks; tick++) await Promise.resolve();
   abaPage.call('cancel', JSON.stringify({ requestId: id }), value => assert.equal(value.status, 'cancelled'));
   abaPage.call('authorize', JSON.stringify({ requestId: id }), value => newStatuses.push(value.status));
   await flush();
   assert.deepEqual(oldStatuses, [], 'cancelled submit must stay silent after ' + ticks + ' microtasks');
   assert.deepEqual(newStatuses, ['invalid_content'], 'reused ID must receive its own rejection after ' + ticks + ' microtasks');
   abaPage.onDestroy(); accepted = true;
 }
 console.log('Expanded SDK regressions: 10 scenarios passed (3 early receipts, active owner, release reservation, raw/module webpage cleanup failure, 3 cancel/reentry timings)');

 // 回放中撤销/替换注册必须保留未消费项，包括同一函数的重注册和ID过滤。
 for (const mode of ['remove', 'replace', 'same-listener']) {
   const Replay = fresh(); const replay = Replay.configure('host-app-id', { cacheDir: '/tmp' });
   for (let i = 0; i < 3; i++) {
     const id = 'replay-' + mode + '-' + i;
     assert.equal(await replay.authorize(id), 'requested'); const req = sent.at(-1);
     replay.onResp(response(wx.SendAuthResp, req, { state: req.state, code: 'fixture-code' }));
   }
   const old = [], next = []; let registration = 0;
   const successor = r => next.push(r.requestId);
   const listener = r => {
     (mode === 'same-listener' && registration ? next : old).push(r.requestId);
     if (!registration) {
       registration++;
       replay.removeListener(listener);
       if (mode === 'replace') replay.addListener(successor);
       if (mode === 'same-listener') replay.addListener(listener);
     }
   };
   replay.addListener(listener, new Set(['replay-' + mode + '-0', 'replay-' + mode + '-1']));
   assert.deepEqual(old, ['replay-' + mode + '-0']);
   if (mode === 'remove') replay.addListener(successor);
   assert.deepEqual(next, ['replay-' + mode + '-1', 'replay-' + mode + '-2']);
   const duplicate = []; replay.addListener(r => duplicate.push(r)); assert.equal(duplicate.length, 0);
 }
 // Map不能在当前回执投递中再次访问回调刚创建的新注册。
 const Live = fresh(); const live = Live.configure('host-app-id', { cacheDir: '/tmp' });
 let liveCalls = 0;
 const liveListener = () => {
   liveCalls++; live.removeListener(liveListener); live.addListener(liveListener);
   assert.equal(liveCalls, 1, 're-registration must not consume the same live receipt twice');
 };
 live.addListener(liveListener); await live.authorize('live-owner-reentry');
 const liveReq = sent.at(-1);
 live.onResp(response(wx.SendAuthResp, liveReq, { state: liveReq.state, code: 'fixture-code' }));
 assert.equal(liveCalls, 1);
 const Limits = fresh(); const limits = Limits.configure('host-app-id', { cacheDir: '/tmp' });
 assert.equal(await limits.authorize('😀'.repeat(65)), 'invalid_content');
 assert.equal(await limits.authorize('e\u0301'.repeat(65)), 'invalid_content');
 assert.equal(await limits.authorize('😀'.repeat(64)), 'requested');
 assert.equal(limits.cancel('😀'.repeat(64)), true);
 for (const saved of [
   { requestId: '😀'.repeat(65), transaction: 'fixture-tx', kind: 'authorization', state: 'state' },
   { requestId: 'id', transaction: 'fixture-tx', kind: 'authorization', state: '😀'.repeat(129) },
 ]) {
   const Restored = fresh(); const restored = Restored.configure('host-app-id', { cacheDir: '/tmp' }, { load: () => saved, save() {} });
   assert.equal(restored.canResume(saved.requestId), false);
   assert.equal(await restored.authorize('fresh-after-invalid-journal'), 'requested');
   assert.equal(restored.cancel('fresh-after-invalid-journal'), true);
 }
 const Boundary = fresh(); const boundarySaved = { requestId: '😀'.repeat(64), transaction: 'fixture-tx', kind: 'authorization', state: '😀'.repeat(128) };
 const boundary = Boundary.configure('host-app-id', { cacheDir: '/tmp' }, { load: () => boundarySaved, save() {} });
 assert.equal(boundary.canResume(boundarySaved.requestId), true);
 console.log('OHOS replay revoke/replace/re-register retains remaining filtered receipts once; UTF16 ID boundaries passed');
 console.log('OHOS cold process, SDK verification, trusted journal, late Kuikly listener, cancellation and replay checks passed');
 console.log('OHOS image repeat submission, no journal/resume/business receipt, busy until SDK ack, early/late receipt isolation and in-flight file retention passed');
 console.log('OHOS OAuth state, transaction, duplicate/late callbacks, concurrency, raw transfer encoding, URL validation and temporary file lifecycle passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
