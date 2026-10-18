# GY CrossKit Wechat Native

适用版本：HAR `0.1.8-rc.1`，配套 Maven `0.1.9`。完整功能与五入口限制见[功能与平台差异](https://github.com/gycrosskit/wechat/blob/har-0.1.8-rc.1/docs/功能与平台差异.md)；构建、固定 Release HAR 消费与 OHPM Registry 可安装性分别见[此版发布记录](https://github.com/gycrosskit/wechat/releases/tag/har-0.1.8-rc.1)。

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` 1.0.23，HAR 要求 API 22。

HAR **0.1.8-rc.1** 与 Maven **0.1.9** 配套，包含 URL 10 KiB UTF-8 限额及标题/描述 UTF-16、UTF-8 截断合同。取消确认协议自旧 HAR0.1.4 提供：持久清除失败保留原 owner，可重试并等待可信迟回执；旧0.1.3 HAR不返回取消ack。Registry 可安装状态与固定 Release HAR 消费以顶部发布记录为准。

当前为独立 HAR RC，修复 SDK 受理前回执及 owner 清理重入；Maven `0.1.9`、Git Pod / SPM `native-0.1.9` 保持原版本。精确 Release HAR、SHA-256、Registry 与设备验收分别记录；候选准备不等于公开可用。Registry 审核通过前从精确 Release 下载并核验冻结 SHA 后使用文件依赖。

```sh
# 仅 Registry 精确版本可安装后使用
ohpm install @gycrosskit/wechat-native@0.1.8-rc.1
```

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

普通图片分享在 SDK 受理后释放提交占用，不产生业务分享回执。文件在已交 SDK 后保留至精确匹配的图片回执；缺回执时等待系统缓存清理，不通过取消或定时器提前删除。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/har-0.1.8-rc.1/README.md)。
