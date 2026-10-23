import { KRAny, KuiklyRenderBaseModule, KuiklyRenderCallback } from '@kuikly-open/render';
import { WechatClient, WechatReceipt, WechatStatus } from './WechatClient';
interface Args { requestId: string; recipientId?: string; senderOpenId?: string; data: string; scene: string; url: string; title: string; description: string; thumbnail: string; merchantId: string; appId: string; packageValue: string; restoredRequestId: string; }
/** 页面 owner 桥；只交付本页持有的请求 ID，销毁取消等待但不接管其他页请求。 */
export class WechatModule extends KuiklyRenderBaseModule {
  /** Kuikly 原生注册名。 */
  static readonly MODULE_NAME: string = 'GycWechat';
  private listener: KuiklyRenderCallback | null = null;
  private destroyed: boolean = false;
  private ids: Set<string> = new Set();
  private submitting: Map<string, Args> = new Map();
  private response = (receipt: WechatReceipt): void => { if (!this.destroyed && this.ids.delete(receipt.requestId)) { this.listener?.(receipt); } };
  syncMode(): boolean { return false; }
  /** 页面线程异步入口；listen 只恢复可信 ID，cancel 清除失败保留原 owner。 */
  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    const client = WechatClient.current();
    if (this.destroyed || !client) { callback?.({ status: 'unsupported' }); return null; }
    if (method === 'listen') {
      let restored = '';
      try { restored = (JSON.parse(typeof params === 'string' ? params : '{}') as Args).restoredRequestId; } catch (_) {}
      if (typeof restored === 'string' && client.canResume(restored, this.response)) { this.ids.add(restored); }
      this.listener = callback; client.addListener(this.response, this.ids); return null;
    }
    if (method === 'unlisten') { this.release(); return null; }
    this.ids.forEach((id: string) => {
      if (!this.submitting.has(id) && !client.canResume(id, this.response)) this.ids.delete(id);
    });
    let args: Args;
    try { args = JSON.parse(typeof params === 'string' ? params : '{}') as Args; } catch (_) { callback?.({ status: 'invalid_content' }); return null; }
    if (!args || typeof args.requestId !== 'string') { callback?.({ status: 'invalid_content' }); return null; }
    if (method === 'cancel') {
      if (!this.ids.has(args.requestId)) { callback?.({ status: 'no_pending' }); return null; }
      try {
        const cancelled = client.cancel(args.requestId);
        this.ids.delete(args.requestId);
        this.submitting.delete(args.requestId);
        callback?.({ status: cancelled ? 'cancelled' : 'no_pending' });
      } catch (_) {
        // 清除持久记录失败时保留 owner；迟回执和下一次取消仍属于同一请求。
        callback?.({ status: 'failed' });
      }
      return null;
    }
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
  private async perform(client: WechatClient, method: string, args: Args): Promise<WechatStatus> {
    if (method === 'authorize') { return client.authorize(args.requestId); }
    if (method === 'image') { return client.shareImage(args.requestId, args.data, args.scene, args.recipientId, args.senderOpenId); }
    if (method === 'webpage') { return client.shareWebPage(args.requestId, args.url, args.title, args.description, args.thumbnail, args.scene); }
    if (method === 'transfer') { return client.openMerchantTransfer(args.requestId, args.merchantId, args.appId, args.packageValue); }
    return 'unsupported';
  }
  private release(): void {
    const client = WechatClient.current();
    const ids = Array.from(this.ids);
    this.listener = null; this.submitting.clear();
    // 清除日志期间保留归属，避免重入页面抢走后被旧 owner 取消。
    try { ids.forEach((id: string) => client?.cancel(id)); }
    finally { this.ids.clear(); client?.removeListener(this.response); }
  }
  onDestroy(): void {
    this.destroyed = true;
    try { this.release(); } finally { super.onDestroy(); }
  }
}
