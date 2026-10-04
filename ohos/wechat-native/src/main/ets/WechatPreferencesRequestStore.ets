import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { WechatPendingRequest, WechatRequestStore } from './WechatClient';

/** 只持久化组件产生的 pending；同步 flush 失败必须阻止 SDK 发送。 */
export class WechatPreferencesRequestStore implements WechatRequestStore {
  private readonly storage: preferences.Preferences;

  constructor(appId: string, context: common.UIAbilityContext, namespace: string = `wechat_pending_${appId}`) {
    if (!appId.trim() || !namespace.trim()) throw new Error('WeChat store configuration missing');
    this.storage = preferences.getPreferencesSync(context, { name: namespace });
  }

  load(): WechatPendingRequest | null {
    const raw = this.storage.getSync('pending', '') as string;
    return raw ? JSON.parse(raw) as WechatPendingRequest : null;
  }

  save(request: WechatPendingRequest | null): void {
    if (request) this.storage.putSync('pending', JSON.stringify(request));
    else this.storage.deleteSync('pending');
    this.storage.flushSync();
  }
}
