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
    const previous = this.storage.getSync('pending', '') as string;
    try {
      if (request) this.storage.putSync('pending', JSON.stringify(request));
      else this.storage.deleteSync('pending');
      this.storage.flushSync();
    } catch (error) {
      // Preferences 先改缓存再 flush；失败不能让同进程恢复误认 journal 已清除。
      try {
        if (previous) this.storage.putSync('pending', previous);
        else this.storage.deleteSync('pending');
      } catch (_) { /* 保留导致持久化失败的原始异常。 */ }
      throw error as Error;
    }
  }
}
