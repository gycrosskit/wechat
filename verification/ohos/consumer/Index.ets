import { WechatClient, WechatModule, WechatReceipt, WechatPendingRequest, WechatRequestStore } from '@gycrosskit/wechat-native';
import { common, Want } from '@kit.AbilityKit';
class Store implements WechatRequestStore {
  private request: WechatPendingRequest | null = null;
  load(): WechatPendingRequest | null { return this.request; }
  save(request: WechatPendingRequest | null): void { this.request = request; }
}
// 这里只检查 API；生产宿主必须使用同步原子持久存储。
export function probe(context: common.UIAbilityContext, want: Want): WechatClient {
  const client = WechatClient.configure('host-app-id', context, new Store());
  client.addListener((receipt: WechatReceipt): void => {});
  return client;
}
export { WechatModule };
