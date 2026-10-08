# GY CrossKit Wechat Native

适用版本：HAR `0.1.6`，配套 Maven `0.1.7`。完整功能与五入口限制见[功能与平台差异](https://github.com/gycrosskit/wechat/blob/0.1.7/docs/功能与平台差异.md)；构建、固定 Release HAR 消费与 OHPM Registry 可安装性分别见[此版发布记录](https://github.com/gycrosskit/wechat/releases/tag/0.1.7)。

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` 1.0.23，HAR 要求 API 22。

HAR **0.1.6** 与 Maven **0.1.7** 配套，包含 URL 10 KiB UTF-8 限额及标题/描述 UTF-16、UTF-8 截断合同。取消确认协议自旧 HAR0.1.4 提供：持久清除失败保留原 owner，可重试并等待可信迟回执；旧0.1.3 HAR不返回取消ack。Registry 可安装状态与固定 Release HAR 消费以顶部发布记录为准。

```sh
ohpm install @gycrosskit/wechat-native@0.1.6
```

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/0.1.7/README.md)。
