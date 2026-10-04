import { WechatClient, WechatModule, WechatReceipt, WechatPreferencesRequestStore } from '@gycrosskit/wechat-native';
import { common, Want } from '@kit.AbilityKit';
// 只编译公开持久化 API；不发起 SDK 授权或业务恢复。
export function probe(context: common.UIAbilityContext, want: Want): WechatClient {
  const client = WechatClient.configure('host-app-id', context, new WechatPreferencesRequestStore('host-app-id', context));
  client.addListener((receipt: WechatReceipt): void => {});
  const cancelled: boolean = client.cancel("compile-only-id");
  return client;
}
export { WechatModule };
