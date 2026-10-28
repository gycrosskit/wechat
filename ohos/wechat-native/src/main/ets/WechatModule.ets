import { KRAny, KuiklyRenderBaseModule, KuiklyRenderCallback } from '@kuikly-open/render';
import { WechatClient, WechatReceipt, WechatStatus } from './WechatClient';
interface Args { requestId: string; recipientId?: string; senderOpenId?: string; data: string; scene: string; url: string; title: string; description: string; thumbnail: string; merchantId: string; appId: string; packageValue: string; restoredRequestId: string; }
/** 页面 owner 桥；只交付本页持有的请求 ID，销毁取消等待但不接管其他页请求。 */
export class WechatModule extends KuiklyRenderBaseModule {
  /** Kuikly 原生注册名。 */
  static readonly MODULE_NAME: string = 'GycWechat';
  private listener: KuiklyRenderCallback | null = null;
  private readonly clientProvider: (() => WechatClient | null) | null;
  private client: WechatClient | null = null;
  private listenRequested: boolean = false;
  private listenerAttached: boolean = false;
  private restoredRequestId: string = '';
  private destroyed: boolean = false;
  private ids: Set<string> = new Set();
  private submitting: Map<string, Args> = new Map();
  private response = (receipt: WechatReceipt): void => { if (!this.destroyed && this.ids.delete(receipt.requestId)) { this.listener?.(receipt); } };
  private submitted = (id: string, status: WechatStatus): void => {
    if (this.destroyed || !this.ids.delete(id)) { return; }
    this.submitting.delete(id);
    this.listener?.({ requestId: id, status });
  };
  /** provider 仅在显式 listen 及其后续请求调用；构造和取消不初始化 SDK。 */
  constructor(clientProvider: (() => WechatClient | null) | null = null) { super(); this.clientProvider = clientProvider; }
  syncMode(): boolean { return false; }
  /** 页面线程异步入口；listen 只恢复可信 ID，cancel 清除失败保留原 owner。 */
  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    if (this.destroyed) { callback?.({ status: 'cancelled' }); return null; }
    if (method === 'unlisten') { this.release(); return null; }
    if (method === 'listen') {
      this.listenRequested = true; this.listenerAttached = false; this.listener = callback;
      this.restoredRequestId = '';
      try { this.restoredRequestId = (JSON.parse(typeof params === 'string' ? params : '{}') as Args)?.restoredRequestId ?? ''; } catch (_) {}
      this.configure(callback); return null;
    }
    let args: Args;
    try { args = JSON.parse(typeof params === 'string' ? params : '{}') as Args; } catch (_) { callback?.({ status: 'invalid_content' }); return null; }
    if (!args || typeof args.requestId !== 'string') { callback?.({ status: 'invalid_content' }); return null; }
    if (method === 'cancel') {
      const client = this.client ?? WechatClient.current();
      if (!this.ids.has(args.requestId)) { callback?.({ status: 'no_pending' }); return null; }
      try {
        const cancelled = client?.cancel(args.requestId) ?? false;
        this.ids.delete(args.requestId);
        this.submitting.delete(args.requestId);
        callback?.({ status: cancelled ? 'cancelled' : 'no_pending' });
      } catch (_) {
        // 清除持久记录失败时保留 owner；迟回执和下一次取消仍属于同一请求。
        callback?.({ status: 'failed' });
      }
      return null;
    }
    if (method !== 'authorize' && method !== 'image' && method !== 'webpage' && method !== 'transfer') { callback?.({ status: 'unsupported' }); return null; }
    if (!this.listenRequested) { callback?.({ status: 'unsupported' }); return null; }
    const client = this.configure(callback); if (!client) { return null; }
    // 恢复监听可同步交付回执，宿主可能在回调内销毁或释放本页。
    if (this.destroyed || !this.listenRequested || !this.listenerAttached) { callback?.({ status: 'cancelled' }); return null; }
    this.ids.forEach((id: string) => {
      if (!this.submitting.has(id) && !client.canResume(id, this.response)) this.ids.delete(id);
    });
    if (this.ids.has(args.requestId) || this.submitting.has(args.requestId)) { callback?.({ status: 'busy' }); return null; }
    this.ids.add(args.requestId);
    // 每次解析得到的参数对象是独有 token，取消后同 ID 重入不能被旧 Promise 消费。
    this.submitting.set(args.requestId, args);
    this.perform(client, method, args).then((status: WechatStatus) => {
      // 回执可以先到并释放接收归属；提交结果有独立生命周期。
      if (this.submitting.get(args.requestId) !== args) { return; }
      this.submitting.delete(args.requestId);
      if (status !== 'requested' || method === 'image') { this.ids.delete(args.requestId); }
      if (!this.destroyed) { callback?.({ status }); }
    }).catch(() => {
      if (this.submitting.get(args.requestId) !== args) { return; }
      this.submitting.delete(args.requestId);
      const pending = client.canResume(args.requestId, this.response);
      if (!pending) { this.ids.delete(args.requestId); }
      // 可信 pending 仍在时不能伪造提交终态。
      if (!this.destroyed) { callback?.({ status: pending ? 'pending' : 'failed' }); }
    });
    return null;
  }
  private configure(callback: KuiklyRenderCallback | null): WechatClient | null {
    let client: WechatClient | null;
    try { client = this.clientProvider ? this.clientProvider() : WechatClient.current(); }
    catch (_) { callback?.({ status: 'failed' }); return null; }
    if (!client) { callback?.({ status: 'unsupported' }); return null; }
    this.client = client;
    if (!this.listenerAttached) {
      if (typeof this.restoredRequestId === 'string' && client.canResume(this.restoredRequestId, this.response)) { this.ids.add(this.restoredRequestId); }
      this.listenerAttached = true;
      client.addListener(this.response, this.ids, this.submitted);
    }
    return client;
  }
  private async perform(client: WechatClient, method: string, args: Args): Promise<WechatStatus> {
    if (method === 'authorize') { return client.authorize(args.requestId); }
    if (method === 'image') { return client.shareImage(args.requestId, args.data, args.scene, args.recipientId, args.senderOpenId); }
    if (method === 'webpage') { return client.shareWebPage(args.requestId, args.url, args.title, args.description, args.thumbnail, args.scene); }
    if (method === 'transfer') { return client.openMerchantTransfer(args.requestId, args.merchantId, args.appId, args.packageValue); }
    return 'unsupported';
  }
  private release(): void {
    const client = this.client ?? WechatClient.current();
    const ids = Array.from(this.ids);
    this.listenRequested = false; this.listenerAttached = false; this.restoredRequestId = '';
    this.listener = null; this.submitting.clear();
    // 单类日志失败不能阻止释放其他类型；全部尝试后保留首个异常。
    let failure: Error | null = null;
    try {
      ids.forEach((id: string) => {
        try { client?.cancel(id); } catch (error) { if (!failure) { failure = error as Error; } }
      });
    } finally { this.ids.clear(); client?.removeListener(this.response); }
    if (failure) { throw failure as Error; }
  }
  onDestroy(): void {
    this.destroyed = true;
    try { this.release(); } finally { super.onDestroy(); }
  }
}
