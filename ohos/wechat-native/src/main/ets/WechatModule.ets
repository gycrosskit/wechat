import { KRAny, KuiklyRenderBaseModule, KuiklyRenderCallback } from '@kuikly-open/render';
import { WechatClient, WechatReceipt, WechatStatus } from './WechatClient';
interface Args { requestId: string; recipientId?: string; senderOpenId?: string; data: string; scene: string; url: string; title: string; description: string; thumbnail: string; merchantId: string; appId: string; packageValue: string; restoredRequestId: string; }
export class WechatModule extends KuiklyRenderBaseModule {
  static readonly MODULE_NAME: string = 'GycWechat';
  private listener: KuiklyRenderCallback | null = null;
  private destroyed: boolean = false;
  private ids: Set<string> = new Set();
  private response = (receipt: WechatReceipt): void => { if (!this.destroyed && this.ids.delete(receipt.requestId)) { this.listener?.(receipt); } };
  syncMode(): boolean { return false; }
  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    const client = WechatClient.current();
    if (this.destroyed || !client) { callback?.({ status: 'unsupported' }); return null; }
    if (method === 'listen') {
      let restored = '';
      try { restored = (JSON.parse(typeof params === 'string' ? params : '{}') as Args).restoredRequestId; } catch (_) {}
      if (typeof restored === 'string' && client.canResume(restored)) { this.ids.add(restored); }
      this.listener = callback; client.addListener(this.response, this.ids); return null;
    }
    if (method === 'unlisten') { this.release(); return null; }
    let args: Args;
    try { args = JSON.parse(typeof params === 'string' ? params : '{}') as Args; } catch (_) { callback?.({ status: 'invalid_content' }); return null; }
    if (!args || typeof args.requestId !== 'string') { callback?.({ status: 'invalid_content' }); return null; }
    if (method === 'cancel') { client.cancel(args.requestId); this.ids.delete(args.requestId); return null; }
    if (this.ids.has(args.requestId)) { callback?.({ status: 'busy' }); return null; }
    this.ids.add(args.requestId);
    this.perform(client, method, args).then((status: WechatStatus) => {
      if (status !== 'requested') { this.ids.delete(args.requestId); }
      if (!this.destroyed) { callback?.({ status }); }
    }).catch(() => { this.ids.delete(args.requestId); if (!this.destroyed) { callback?.({ status: 'failed' }); } });
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
    const ids = Array.from(this.ids); this.ids.clear();
    client?.removeListener(this.response); this.listener = null;
    ids.forEach((id: string) => client?.cancel(id));
  }
  onDestroy(): void { this.destroyed = true; this.release(); super.onDestroy(); }
}
