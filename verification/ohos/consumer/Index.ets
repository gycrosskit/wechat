import { WechatClient, WechatModule, WechatReceipt } from '@gycrosskit/wechat-native';
import { common, Want } from '@kit.AbilityKit';
export function probe(context: common.UIAbilityContext, want: Want): WechatClient {
  const client = WechatClient.configure('host-app-id', context);
  client.addListener((receipt: WechatReceipt): void => {});
  return client;
}
export { WechatModule };
