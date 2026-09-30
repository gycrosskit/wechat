import { common, Want } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util, url } from '@kit.ArkTS';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import * as wx from '@tencent/wechat_open_sdk';

export type WechatStatus = 'requested' | 'busy' | 'not_installed' | 'unsupported' | 'invalid_content' | 'failed' | 'cancelled';
export interface WechatReceipt { requestId: string; kind: string; errorCode: number; authorizationCode?: string; pageResult?: string; }
interface Pending { id: string; transaction: string; kind: string; state: string; path: string; cancelled: boolean; }
interface PageResult { result?: string; }
type Listener = (receipt: WechatReceipt) => void;
class QuietLog implements wx.LogInterface { print(_level: wx.LogLevel, _tag: string, _message: string): void {} }

/** 宿主配置一次后，认证、分享和 EntryAbility 回跳共用同一 SDK 入口。 */
export class WechatClient implements wx.WXApiEventHandler {
  private static instance: WechatClient | null = null;
  private api: wx.WXApi;
  private pending: Pending | null = null;
  private usedIds: Set<string> = new Set();
  private listeners: Set<Listener> = new Set();
  private appId: string;
  private context: common.UIAbilityContext;
  private constructor(appId: string, context: common.UIAbilityContext) {
    this.appId = appId; this.context = context;
    wx.Log.setLogImpl(new QuietLog());
    this.api = wx.WXAPIFactory.createWXAPI(appId, context);
    this.api.setPayReportEnabled(false);
  }
  static configure(appId: string, context: common.UIAbilityContext): WechatClient {
    if (!appId.trim()) { throw new Error('WeChat appId missing'); }
    if (WechatClient.instance && WechatClient.instance.appId !== appId) { throw new Error('WeChat already configured'); }
    if (!WechatClient.instance) { WechatClient.instance = new WechatClient(appId, context); }
    return WechatClient.instance;
  }
  static current(): WechatClient | null { return WechatClient.instance; }
  addListener(listener: Listener): void { this.listeners.add(listener); }
  removeListener(listener: Listener): void { this.listeners.delete(listener); }
  handleWant(want: Want): boolean { try { return this.api.handleWant(want, this); } catch (_) { return false; } }
  onReq(_req: wx.BaseReq): void {}
  onResp(resp: wx.BaseResp): void {
    const current = this.pending;
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
    this.pending = null;
    this.removeFile(current.path);
    this.listeners.forEach((listener: Listener) => listener(result));
  }
  async authorize(id: string): Promise<WechatStatus> {
    const rejected = this.begin(id, 'authorization'); if (rejected) { return rejected; }
    const pending = this.pending!;
    try {
      pending.state = new util.Base64Helper().encodeToStringSync(cryptoFramework.createRandom().generateRandomSync(32).data);
      const req = new wx.SendAuthReq(); req.scope = 'snsapi_userinfo'; req.state = pending.state;
      return await this.send(req, pending);
    } catch (_) { return this.fail(pending, 'failed'); }
  }
  async shareImage(id: string, base64: string, scene: string): Promise<WechatStatus> {
    const rejected = this.begin(id, 'share'); if (rejected) { return rejected; }
    const pending = this.pending!;
    if (!this.validScene(scene) || typeof base64 !== 'string' || !base64 || base64.length > 14 * 1024 * 1024) { return this.fail(pending, 'invalid_content'); }
    let source: image.ImageSource | null = null;
    try {
      const bytes = new util.Base64Helper().decodeSync(base64);
      if (!bytes.length || bytes.length > 10 * 1024 * 1024) { return this.fail(pending, 'invalid_content'); }
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const info = await source.getImageInfo();
      if (info.mimeType !== 'image/png' && info.mimeType !== 'image/jpeg') { return this.fail(pending, 'unsupported'); }
      const thumb = await this.thumbnail(source);
      if (!thumb) { return this.fail(pending, 'invalid_content'); }
      if (pending.cancelled) { return 'cancelled'; }
      pending.path = `${this.context.cacheDir}/gyc_wechat_${util.generateRandomUUID()}.${info.mimeType === 'image/png' ? 'png' : 'jpg'}`;
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
      return this.sendShare(message, scene, pending);
    } catch (_) { return this.fail(pending, pending.cancelled ? 'cancelled' : 'invalid_content'); }
    finally { if (source) { await source.release(); } if (pending.cancelled) { await this.removeFile(pending.path); } }
  }
  async shareWebPage(id: string, address: string, title: string, description: string, thumbBase64: string, scene: string): Promise<WechatStatus> {
    const rejected = this.begin(id, 'share'); if (rejected) { return rejected; }
    const pending = this.pending!;
    let source: image.ImageSource | null = null;
    try {
      if (!this.validScene(scene) || !this.validUrl(address) || typeof title !== 'string' || typeof description !== 'string' || typeof thumbBase64 !== 'string' || !thumbBase64 || thumbBase64.length > 14 * 1024 * 1024) { return this.fail(pending, 'invalid_content'); }
      const bytes = new util.Base64Helper().decodeSync(thumbBase64);
      if (!bytes.length || bytes.length > 10 * 1024 * 1024) { return this.fail(pending, 'invalid_content'); }
      source = image.createImageSource(bytes.buffer as ArrayBuffer);
      const thumb = await this.thumbnail(source);
      if (!thumb) { return this.fail(pending, 'invalid_content'); }
      const object = new wx.WXWebpageObject(); object.webpageUrl = address;
      const message = new wx.WXMediaMessage(); message.mediaObject = object; message.title = title; message.description = description; message.thumbData = thumb;
      return this.sendShare(message, scene, pending);
    } catch (_) { return this.fail(pending, 'invalid_content'); }
    finally { if (source) { await source.release(); } }
  }
  async openMerchantTransfer(id: string, merchantId: string, appId: string, packageValue: string): Promise<WechatStatus> {
    const rejected = this.begin(id, 'merchant_transfer'); if (rejected) { return rejected; }
    const pending = this.pending!;
    if (typeof merchantId !== 'string' || !merchantId.trim() || typeof appId !== 'string' || !appId.trim() || typeof packageValue !== 'string' || !packageValue.trim()) { return this.fail(pending, 'invalid_content'); }
    const req = new wx.OpenBusinessViewReq(); req.businessType = 'requestMerchantTransfer';
    req.query = `mchId=${this.encode(merchantId)}&appId=${this.encode(appId)}&package=${this.encode(packageValue)}`;
    return this.send(req, pending);
  }
  cancel(id: string): void {
    const pending = this.pending;
    if (!pending || pending.id !== id) { return; }
    pending.cancelled = true; this.pending = null; this.removeFile(pending.path);
  }
  private begin(id: string, kind: string): WechatStatus | null {
    if (typeof id !== 'string' || !id.trim() || id.length > 128 || this.usedIds.has(id)) { return 'invalid_content'; }
    if (this.pending) { return 'busy'; }
    this.usedIds.add(id);
    try { if (!this.api.isWXAppInstalled()) { return 'not_installed'; } } catch (_) { return 'failed'; }
    this.pending = { id, transaction: util.generateRandomUUID(), kind, state: '', path: '', cancelled: false };
    return null;
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
      const accepted = await this.api.sendReq(this.context, req);
      if (pending.cancelled) { await this.removeFile(pending.path); return 'cancelled'; }
      if (accepted) { return 'requested'; }
    } catch (_) {}
    return this.fail(pending, 'failed');
  }
  private fail(pending: Pending, status: WechatStatus): WechatStatus {
    if (this.pending === pending) { this.pending = null; }
    this.removeFile(pending.path); return status;
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
  private validScene(scene: string): boolean { return scene === 'session' || scene === 'timeline'; }
  private validUrl(address: string): boolean {
    if (typeof address !== 'string' || address.length > 10 * 1024) { return false; }
    try { const u = new url.URL(address); return (u.protocol === 'https:' || u.protocol === 'http:') && !!u.hostname && !u.username && !u.password; } catch (_) { return false; }
  }
  private encode(value: string): string { return encodeURIComponent(value).replace(/[!'()*]/g, (s: string) => `%${s.charCodeAt(0).toString(16).toUpperCase()}`); }
  private async removeFile(path: string): Promise<void> { if (path) { try { await fs.unlink(path); } catch (_) {} } }
}
