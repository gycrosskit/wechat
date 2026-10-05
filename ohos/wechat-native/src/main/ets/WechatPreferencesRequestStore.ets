import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { WechatPendingRequest, WechatRequestStore } from './WechatClient';

/** 只持久化组件产生的 pending；同步 flush 失败必须阻止 SDK 发送。 */
export class WechatPreferencesRequestStore implements WechatRequestStore {
  private readonly storage: preferences.Preferences;

  /** 默认 namespace 为 wechat_pending_appId；旧宿主可显式提供原存储名，不迁移未知内容。 */
  constructor(appId: string, context: common.UIAbilityContext, namespace: string = `wechat_pending_${appId}`) {
    if (!appId.trim() || !namespace.trim()) throw new Error('WeChat store configuration missing');
    this.storage = preferences.getPreferencesSync(context, { name: namespace });
  }

  /** 同步读取可信记录；损坏 JSON 抛错，不覆盖或猜测恢复。 */
  load(): WechatPendingRequest | null {
    const raw = this.storage.getSync('pending', '') as string;
    return raw ? JSON.parse(raw) as WechatPendingRequest : null;
  }

  /** 同步 flush；null 清除记录，失败恢复同进程缓存并保留原始异常。 */
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
