import { common, Want } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util, url } from '@kit.ArkTS';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import * as wx from '@tencent/wechat_open_sdk';

/** 提交状态，requested 仅表示 SDK 受理；最终回执单独交付。 */
export type WechatStatus = 'requested' | 'busy' | 'not_installed' | 'unsupported' | 'invalid_content' | 'failed' | 'cancelled';
/** 已验证 transaction/state 的回执；OAuth code 禁止日志/持久化，pageResult 不证明到账。 */
export interface WechatReceipt { requestId: string; kind: string; errorCode: number; authorizationCode?: string; pageResult?: string; }
/** 可信本地等待：requestId/transaction 最多 128 字符，授权 state 非空最多 256，其余 state 为空串。 */
export interface WechatPendingRequest { requestId: string; transaction: string; kind: string; state: string; }
/** 同一 App 的可信本地记录；同步原子保存，失败抛异常。禁止从 Want/页面参数构造。 */
export interface WechatRequestStore {
  /** 同步读取可信等待；不可读抛错，禁止覆写未知内容。 */
  load(): WechatPendingRequest | null;
  /** 原子保存；null 必须持久清除，失败阻止提交和结果消费。 */
  save(request: WechatPendingRequest | null): void;
}
interface Pending { id: string; transaction: string; kind: string; state: string; path: string; cancelled: boolean; context: common.UIAbilityContext; cancelWaiting: (() => void) | null; }
interface PageResult { result?: string; }
type Listener = (receipt: WechatReceipt) => void;
interface ListenerRegistration { ids: Set<string> | null; onSubmitted: ((id: string, status: WechatStatus) => void) | null; }
class QuietLog implements wx.LogInterface { print(_level: wx.LogLevel, _tag: string, _message: string): void {} }

/** 宿主配置一次后，认证、分享和 EntryAbility 回跳共用同一 SDK 入口。 */
export class WechatClient implements wx.WXApiEventHandler {
  private static instance: WechatClient | null = null;
  private static wants: Want[] = [];
  private api: wx.WXApi;
  private store: WechatRequestStore | null;
  private receipts: WechatReceipt[] = [];
  private usedTransactions: Set<string> = new Set();
  private currentRequests: Map<string, Pending> = new Map();
  private journal: Pending | null = null;
  private imageFiles: Map<string, string> = new Map();
  private usedIds: Set<string> = new Set();
  private listeners: Map<Listener, ListenerRegistration> = new Map();
  private appId: string;
  private context: common.UIAbilityContext;
  private constructor(appId: string, context: common.UIAbilityContext, store: WechatRequestStore | null) {
    this.store = store;
    const saved = store?.load();
    if (saved && this.validRequest(saved)) {
      const pending: Pending = { id: saved.requestId, transaction: saved.transaction, kind: saved.kind, state: saved.state, path: '', cancelled: false, context, cancelWaiting: null };
      this.currentRequests.set(saved.kind, pending); this.journal = pending;
      this.usedIds.add(saved.requestId); this.usedTransactions.add(saved.transaction);
    }
    this.appId = appId; this.context = context;
    wx.Log.setLogImpl(new QuietLog());
    this.api = wx.WXAPIFactory.createWXAPI(appId, context);
    this.api.setPayReportEnabled(false);
  }
  /** UI 线程配置进程实例；同一 appId 复用并更新调用方 context，换 AppKey 拒绝，先前 Want 仍交官方 SDK 验证。 */
  static configure(appId: string, context: common.UIAbilityContext, store: WechatRequestStore | null = null): WechatClient {
    if (!appId.trim()) { throw new Error('WeChat appId missing'); }
    if (WechatClient.instance && WechatClient.instance.appId !== appId) { throw new Error('WeChat already configured'); }
    if (!WechatClient.instance) {
      WechatClient.instance = new WechatClient(appId, context, store);
      const wants = WechatClient.wants; WechatClient.wants = [];
      wants.forEach((want: Want) => WechatClient.instance?.handleWant(want));
    } else {
      WechatClient.instance.context = context;
    }
    return WechatClient.instance;
  }
  /** 返回已配置进程入口，未配置为 null。 */
  static current(): WechatClient | null { return WechatClient.instance; }
  /** EntryAbility 尚未初始化时仅暂存原始 Want，配置完成后仍交官方 SDK 验证。 */
  static forwardWant(want: Want): boolean {
    if (WechatClient.instance) { return WechatClient.instance.handleWant(want); }
    if (WechatClient.wants.length === 4) { WechatClient.wants.shift(); }
    WechatClient.wants.push(want); return false;
  }
  /** 只恢复尚无其他页面持有的可信 pending 或已验证缓存回执。 */
  canResume(id: string, owner: Listener | null = null): boolean {
    let owned = false;
    this.listeners.forEach((registration: ListenerRegistration, listener: Listener) => {
      if (listener !== owner && registration.ids?.has(id)) { owned = true; }
    });
    return !owned && (Array.from(this.currentRequests.values()).some((request: Pending) => request.id === id && request.kind !== 'image') || this.receipts.some((receipt: WechatReceipt) => receipt.requestId === id));
  }
  /** UI 线程附着监听；ids 为 null 接收全部，onSubmitted 交付本地替换取消，不伪造 SDK 回执。 */
  addListener(listener: Listener, ids: Set<string> | null = null, onSubmitted: ((id: string, status: WechatStatus) => void) | null = null): void {
    const registration: ListenerRegistration = { ids, onSubmitted };
    this.listeners.set(listener, registration);
    // 逐条移出缓冲，撤销/同函数重注册后不再调用旧 owner，也不丢其余项。
    while (this.listeners.get(listener) === registration) {
      const index = this.receipts.findIndex((receipt: WechatReceipt) => !ids || ids.has(receipt.requestId));
      if (index < 0) { break; }
      const receipt = this.receipts.splice(index, 1)[0];
      listener(receipt);
    }
  }
  /** 移除指定监听，不取消在途请求。 */
  removeListener(listener: Listener): void { this.listeners.delete(listener); }
  /** 原始 Want 交官方 SDK 校验，异常返回 false；不直接从 Want 构造关联凭据。 */
  handleWant(want: Want): boolean { try { return this.api.handleWant(want, this); } catch (_) { return false; } }
  onReq(_req: wx.BaseReq): void {}
  onResp(resp: wx.BaseResp): void {
    const transaction = resp.transaction;
    if (resp instanceof wx.SendMessageToWXResp && transaction) {
      const path = this.imageFiles.get(transaction);
      if (path) {
        this.imageFiles.delete(transaction); this.removeFile(path);
        return;
      }
    }
    const current = Array.from(this.currentRequests.values()).find((request: Pending) => request.transaction === transaction);
    if (!current || current.cancelled || resp.transaction !== current.transaction) { return; }
    let result: WechatReceipt;
    if (current.kind === 'authorization' && resp instanceof wx.SendAuthResp) {
      // 成功、取消、失败都匹配 state；缺失 state 只能由宿主取消等待。
      if (resp.state !== current.state) { return; }
      const code = resp.errCode === 0 && resp.code?.trim() ? resp.code : undefined;
      result = { requestId: current.id, kind: current.kind, errorCode: resp.errCode === 0 && !code ? -1 : resp.errCode, authorizationCode: code };
    } else if (current.kind === 'share' && resp instanceof wx.SendMessageToWXResp) {
      result = { requestId: current.id, kind: current.kind, errorCode: resp.errCode };
    } else if (current.kind === 'merchant_transfer' && resp instanceof wx.OpenBusinessViewResp && resp.businessType === 'requestMerchantTransfer') {
      let page: string | undefined = undefined;
      try { const parsed = JSON.parse(resp.extMsg ?? '{}') as PageResult; if (typeof parsed?.result === 'string') { page = parsed.result; } } catch (_) {}
      result = { requestId: current.id, kind: current.kind, errorCode: resp.errCode, pageResult: page };
    } else { return; }
    this.clearJournal(current);
    this.currentRequests.delete(this.lane(current.kind));
    this.removeFile(current.path);
    this.deliver(result);
  }
  private deliver(result: WechatReceipt): void {
    let delivered = false;
    // Map 原地重注册会被 live 遍历再次访问；当前回执只交投递开始时的注册。
    const listeners = new Map(this.listeners);
    listeners.forEach((registration: ListenerRegistration, listener: Listener) => {
      if (this.listeners.get(listener) === registration && (!registration.ids || registration.ids.has(result.requestId))) {
        delivered = true; listener(result);
      }
    });
    if (!delivered) {
      // ponytail: 最多缓存 64 笔；跨进程结果交付由宿主业务存储承担。
      if (this.receipts.length === 64) { this.receipts.shift(); }
      this.receipts.push(result);
    }
  }
  /** 开始 OAuth 并持久保存随机 state；成功仅表示 SDK 受理，后端负责换票。 */
  async authorize(id: string): Promise<WechatStatus> {
    const pending = this.begin(id, 'authorization'); if (typeof pending === 'string') { return pending; }
    return this.wait(pending, async () => {
      try {
        const req = new wx.SendAuthReq(); req.scope = 'snsapi_userinfo'; req.state = pending.state;
        return await this.send(req, pending);
      } catch (_) { return this.fail(pending, 'failed'); }
    });
  }
  /** Base64 编码 PNG/JPEG 最大 25 MiB；仅返回 SDK 受理，文件保留到匹配回执后删除。 */
  async shareImage(id: string, base64: string, scene: string, recipientId?: string, _senderOpenId?: string): Promise<WechatStatus> {
    if (recipientId !== undefined) { return typeof recipientId !== 'string' || !recipientId.trim() || scene !== 'session' ? 'invalid_content' : 'unsupported'; }
    if (!this.validScene(scene) || typeof base64 !== 'string' || !base64 || base64.length > Math.ceil(25 * 1024 * 1024 / 3) * 4) { return 'invalid_content'; }
    let bytes: Uint8Array;
    try { bytes = new util.Base64Helper().decodeSync(base64); } catch (_) { return 'invalid_content'; }
    if (!bytes.length || bytes.length > 25 * 1024 * 1024) { return 'invalid_content'; }
    const pending = this.begin(id, 'image'); if (typeof pending === 'string') { return pending; }
    return this.wait(pending, async () => {
      let source: image.ImageSource | null = null;
      try {
        source = image.createImageSource(bytes.buffer as ArrayBuffer);
        const info = await source.getImageInfo();
        if (info.mimeType !== 'image/png' && info.mimeType !== 'image/jpeg') { return this.fail(pending, 'unsupported'); }
        const thumb = await this.thumbnail(source);
        if (!thumb) { return this.fail(pending, 'invalid_content'); }
        if (pending.cancelled) { return 'cancelled'; }
        pending.path = `${pending.context.cacheDir}/gyc_wechat_${util.generateRandomUUID()}.${info.mimeType === 'image/png' ? 'png' : 'jpg'}`;
        const file = await fs.open(pending.path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          let offset = 0;
          while (offset < bytes.length) {
            const count = await fs.write(file.fd, (bytes.buffer as ArrayBuffer).slice(offset));
            if (count <= 0) { throw new Error('Incomplete image'); }
            offset += count;
          }
        } finally { await fs.close(file); }
        const object = new wx.WXImageObject(); object.uri = fileUri.getUriFromPath(pending.path);
        const message = new wx.WXMediaMessage(); message.mediaObject = object; message.thumbData = thumb;
        return await this.sendShare(message, scene, pending);
      } catch (_) { return this.fail(pending, pending.cancelled ? 'cancelled' : 'invalid_content'); }
      finally {
        // 已受理不能因本地资源释放失败变为失败，避免宿主重复发送。
        if (source) { try { await source.release(); } catch (_) {} }
      }
    });
  }
  /** 分享无凭据 HTTP(S) 页面；缩略图是 Base64 图片，标题/描述同时受字符与字节限制。 */
  async shareWebPage(id: string, address: string, title: string, description: string, thumbBase64: string, scene: string): Promise<WechatStatus> {
    if (!this.validScene(scene) || !this.validUrl(address) || typeof title !== 'string' || typeof description !== 'string' || typeof thumbBase64 !== 'string' || !thumbBase64 || thumbBase64.length > Math.ceil(25 * 1024 * 1024 / 3) * 4) { return 'invalid_content'; }
    let bytes: Uint8Array;
    try { bytes = new util.Base64Helper().decodeSync(thumbBase64); } catch (_) { return 'invalid_content'; }
    if (!bytes.length || bytes.length > 25 * 1024 * 1024) { return 'invalid_content'; }
    const pending = this.begin(id, 'share'); if (typeof pending === 'string') { return pending; }
    return this.wait(pending, async () => {
      let source: image.ImageSource | null = null;
      try {
        source = image.createImageSource(bytes.buffer as ArrayBuffer);
        const thumb = await this.thumbnail(source);
        if (!thumb) { return this.fail(pending, 'invalid_content'); }
        const object = new wx.WXWebpageObject(); object.webpageUrl = address;
        const message = new wx.WXMediaMessage(); message.mediaObject = object; message.title = this.text(title, 256, 512); message.description = this.text(description, 512, 1024); message.thumbData = thumb;
        return this.sendShare(message, scene, pending);
      } catch (_) { return this.fail(pending, 'invalid_content'); }
      finally { if (source) { try { await source.release(); } catch (_) {} } }
    });
  }
  /** 打开商家确认页，packageValue 来自可信后端并原样编码；回执不证明到账。 */
  async openMerchantTransfer(id: string, merchantId: string, appId: string, packageValue: string): Promise<WechatStatus> {
    if (typeof merchantId !== 'string' || !merchantId.trim() || typeof appId !== 'string' || !appId.trim() || typeof packageValue !== 'string' || !packageValue.trim()) { return 'invalid_content'; }
    const req = new wx.OpenBusinessViewReq(); req.businessType = 'requestMerchantTransfer';
    try { req.query = `mchId=${this.encode(merchantId)}&appId=${this.encode(appId)}&package=${this.encode(packageValue)}`; }
    catch (_) { return 'invalid_content'; }
    const pending = this.begin(id, 'merchant_transfer'); if (typeof pending === 'string') { return pending; }
    return this.wait(pending, async () => this.send(req, pending));
  }
  /** 清除业务等待；未发送图片可删除，SDK 已持有的 URI 等匹配回执，不能关闭外部微信页面。 */
  cancel(id: string): boolean {
    this.receipts = this.receipts.filter((receipt: WechatReceipt) => receipt.requestId !== id);
    const pending = Array.from(this.currentRequests.values()).find((request: Pending) => request.id === id);
    if (!pending) { return false; }
    this.clearJournal(pending);
    this.currentRequests.delete(this.lane(pending.kind));
    this.invalidate(pending);
    return true;
  }
  private lane(kind: string): string { return kind === 'image' ? 'share' : kind; }
  private begin(id: string, kind: string): Pending | WechatStatus {
    if (typeof id !== 'string' || !id.trim() || id.length > 128 || this.usedIds.has(id)) { return 'invalid_content'; }
    this.usedIds.add(id);
    try { if (!this.api.isWXAppInstalled()) { return 'not_installed'; } } catch (_) { return 'failed'; }
    const transaction = util.generateRandomUUID();
    if (this.usedTransactions.has(transaction)) { return 'failed'; }
    this.usedTransactions.add(transaction);
    const pending: Pending = { id, transaction, kind, state: '', path: '', cancelled: false, context: this.context, cancelWaiting: null };
    if (kind === 'authorization') {
      pending.state = new util.Base64Helper().encodeToStringSync(cryptoFramework.createRandom().generateRandomSync(32).data);
      // 原子替换 OAuth 日志成功后才作废旧轮；其他类型始终不覆盖授权日志。
      this.store?.save({ requestId: id, transaction, kind, state: pending.state });
      this.journal = pending;
    }
    const lane = this.lane(kind), previous = this.currentRequests.get(lane);
    if (previous && this.journal === previous) { this.clearJournal(previous); }
    this.currentRequests.set(lane, pending);
    if (previous) {
      this.invalidate(previous);
      const listeners = new Map(this.listeners);
      listeners.forEach((registration: ListenerRegistration, listener: Listener) => {
        if (this.listeners.get(listener) === registration && (!registration.ids || registration.ids.has(previous.id))) { registration.onSubmitted?.(previous.id, 'cancelled'); }
      });
    }
    return pending;
  }
  private invalidate(pending: Pending): void {
    pending.cancelled = true; pending.cancelWaiting?.(); pending.cancelWaiting = null;
    if (!this.imageFiles.has(pending.transaction)) { this.removeFile(pending.path); }
  }
  private clearJournal(pending: Pending): void {
    if (this.journal !== pending) { return; }
    this.store?.save(null); this.journal = null;
  }
  private wait(pending: Pending, action: () => Promise<WechatStatus>): Promise<WechatStatus> {
    if (pending.cancelled) { return Promise.resolve('cancelled'); }
    return new Promise<WechatStatus>((resolve, reject) => {
      pending.cancelWaiting = () => resolve('cancelled');
      action().then((status: WechatStatus) => { pending.cancelWaiting = null; resolve(status); }, reject);
    });
  }
  private sendShare(message: wx.WXMediaMessage, scene: string, pending: Pending): Promise<WechatStatus> {
    const req = new wx.SendMessageToWXReq(); req.message = message; req.scene = scene === 'timeline' ? wx.SendMessageToWXReq.WXSceneTimeline : wx.SendMessageToWXReq.WXSceneSession;
    return this.send(req, pending);
  }
  private async send(req: wx.BaseReq, pending: Pending): Promise<WechatStatus> {
    if (pending.cancelled) { await this.removeFile(pending.path); return 'cancelled'; }
    req.transaction = pending.transaction;
    try {
      if (!req.checkArgs()) { return this.fail(pending, 'invalid_content'); }
      // 图片 URI 生命周期独立于业务当前轮；OAuth 已在安装新轮前原子保存。
      if (pending.kind === 'image') { this.imageFiles.set(pending.transaction, pending.path); }
      const accepted = await this.api.sendReq(pending.context, req);
      if (accepted) {
        // shortcut: SDK 1.0.23 仅授予 Want URI 读取权，缺回执时由系统回收 cache。
        if (pending.kind === 'image' && this.currentRequests.get('share') === pending) { this.currentRequests.delete('share'); }
        return pending.cancelled ? 'cancelled' : 'requested';
      }
    } catch (_) {}
    return this.fail(pending, pending.cancelled ? 'cancelled' : 'failed');
  }
  private fail(pending: Pending, status: WechatStatus): WechatStatus {
    if (this.currentRequests.get(this.lane(pending.kind)) === pending) {
      this.clearJournal(pending);
      this.currentRequests.delete(this.lane(pending.kind));
    }
    this.imageFiles.delete(pending.transaction);
    this.removeFile(pending.path); return pending.cancelled ? 'cancelled' : status;
  }
  private async thumbnail(source: image.ImageSource): Promise<Uint8Array | null> {
    const info = await source.getImageInfo();
    if (info.size.width <= 0 || info.size.height <= 0) { return null; }
    const scale = Math.min(1, 160 / Math.max(info.size.width, info.size.height));
    const pixels = await source.createPixelMap({ desiredSize: { width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) } });
    try {
      const packer = image.createImagePacker();
      try { const data = new Uint8Array(await packer.packing(pixels, { format: 'image/jpeg', quality: 60 })); return data.length <= 32 * 1024 ? data : null; }
      finally { await packer.release(); }
    } finally { await pixels.release(); }
  }
  private validRequest(request: WechatPendingRequest): boolean {
    return typeof request.requestId === 'string' && !!request.requestId.trim() && request.requestId.length <= 128 &&
      typeof request.transaction === 'string' && !!request.transaction.trim() && request.transaction.length <= 128 &&
      typeof request.state === 'string' && (request.kind === 'authorization' ? !!request.state.trim() && request.state.length <= 256 :
      (request.kind === 'share' || request.kind === 'merchant_transfer') && request.state === '');
  }
  private text(value: string, characters: number, bytes: number): string {
    let text = value.slice(0, characters);
    const encoder = new util.TextEncoder();
    while (encoder.encodeInto(text).length > bytes || /[\uD800-\uDBFF]$/.test(text)) { text = text.slice(0, -1); }
    return text;
  }
  private validScene(scene: string): boolean { return scene === 'session' || scene === 'timeline'; }
  private validUrl(address: string): boolean {
    if (typeof address !== 'string' || new util.TextEncoder().encodeInto(address).length > 10 * 1024) { return false; }
    try { const u = new url.URL(address); return (u.protocol === 'https:' || u.protocol === 'http:') && !!u.hostname && !u.username && !u.password; } catch (_) { return false; }
  }
  private encode(value: string): string { return encodeURIComponent(value).replace(/[!'()*]/g, (s: string) => `%${s.charCodeAt(0).toString(16).toUpperCase()}`); }
  private async removeFile(path: string): Promise<void> { if (path) { try { await fs.unlink(path); } catch (_) {} } }
}
