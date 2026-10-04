# GY CrossKit Wechat Native

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` 1.0.23，HAR 要求 API 22。

本轮 HAR 候选 **0.1.4** 增加取消确认：须与 Kuikly Maven 0.1.4 配套，持久清除失败保留原 owner，允许重试与真实迟回执。Release 发布/下载与正式 Registry 安装分别验证，尚待完成。旧 0.1.3 HAR 不返回取消 ack。

```sh
ohpm install @gycrosskit/wechat-native@0.1.4
```

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/0.1.4/README.md)。
