# 微信原生组件

接线、边界和验证结果请参阅根 README.md；SDK 为 @tencent/wechat_open_sdk 1.0.23。

图片输入上限 25 MiB（纯 Base64）；标题/描述沿用宿主 256/512 字符并按 UTF-8 512/1024 字节截断。`shareImage(id, base64, scene, recipientId?, senderOpenId?)` 保留普通分享调用；SDK 1.0.23 缺少指定联系人 API，非空可信目标返回 `unsupported`，不降级普通好友。senderOpenId 仅为跨端契约透传，本端不使用；cancel/dispose/trustedStore 保持原契约。

可信恢复使用宿主同步原子 `WechatRequestStore`，发送前保存、消费/取消清除。初始化前的 Want 用 `WechatClient.forwardWant` 缓存，初始化后由官方 SDK 校验。迟监听缓存归一结果；Kuikly `listen` 的 `restoredRequestId` 仅认领已有可信记录，不从页面恢复 transaction/state。详细接线与 iOS 无 transaction 边界见根 README。

```sh
ohpm install @gycrosskit/wechat-native@0.1.0
```
