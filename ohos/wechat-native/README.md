# GY CrossKit Wechat Native

2026-10-08 当前源码与三端/五入口边界见[功能与平台差异](../../docs/功能与平台差异.md)；本包只承担上文所述原生能力，以下版本和渠道记录按各自日期阅读。

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` 1.0.23，HAR 要求 API 22。

HAR **0.1.4** 的取消确认协议与 Maven 0.1.4/0.1.5配套，持久清除失败保留原 owner，允许重试与真实迟回执。Release提供与Registry安装分别按根README验收记录核对；本次未重新查询渠道。当前未发布源码还统一URL UTF-8限额和标题截断，不代表已有0.1.4包已含此修复。旧0.1.3 HAR不返回取消ack。

```sh
ohpm install @gycrosskit/wechat-native@0.1.4
```

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/0.1.4/README.md)。
