# GY CrossKit Wechat Native

> 当前源码候选统一为 **1.0.1**：Maven（core/Kuikly）、iOS Pod 与 OHPM 使用同版；尚未发布，示例坐标须待发布后远程消费。本地验证使用显式源码/本地 HAR，Kuikly 基线为 2.29.1，真机与新版本远程消费另验。

未发布源码修复：网页分享在 SDK 受理后释放发送占用，不再等待最终回执才能重试。Android/OHOS 复用转账的有界回执关联；iOS 保留单笔候选，旧分享无回执时再次分享后只能交付 `UNATTRIBUTED`。本修复尚未发版，不包含在下述已冻结版本内，也不升级和合康正式提审依赖。

适用版本：HAR `0.1.9-rc.1`，配套 Maven `0.1.9`。完整功能与五入口限制见[功能与平台差异](https://github.com/gycrosskit/wechat/blob/har-0.1.9-rc.1/docs/功能与平台差异.md)；构建、固定 Release HAR 消费与 OHPM Registry 可安装性分别见[此版发布记录](https://github.com/gycrosskit/wechat/releases/tag/har-0.1.9-rc.1)。

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` 1.0.23，HAR 要求 API 22。

HAR **0.1.9-rc.1** 与 Maven **0.1.9** 配套，包含 URL 10 KiB UTF-8 限额及标题/描述 UTF-16、UTF-8 截断合同。取消确认协议自旧 HAR0.1.4 提供：持久清除失败保留原 owner，可重试并等待可信迟回执；旧0.1.3 HAR不返回取消ack。Registry 可安装状态与固定 Release HAR 消费以顶部发布记录为准。

当前为独立 HAR RC，修复 SDK 受理前回执及 owner 清理重入；Maven `1.0.1`、Git Pod / SPM `native-1.0.1` 保持原版本。精确 Release HAR、SHA-256、Registry 与设备验收分别记录；候选准备不等于公开可用。Registry 审核通过前从精确 Release 下载并核验冻结 SHA 后使用文件依赖。

```sh
# 仅 Registry 精确版本可安装后使用
ohpm install @gycrosskit/wechat-native@1.0.1
```

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

普通图片分享在 SDK 受理后释放提交占用，不产生业务分享回执。文件在已交 SDK 后保留至精确匹配的图片回执；缺回执时等待系统缓存清理，不通过取消或定时器提前删除。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/har-1.0.1/README.md)。

## 1.0.1 发布候选

以下为本版合同；发布、Registry 审核和实际安装/编译须分别验证，详见精确 HAR Release。

多 Ability 宿主须在每次操作前，以实际前台调用方的 `UIAbilityContext` 再次 `configure`。同 AppID 只更新后继请求的 context，不创建第二 SDK、不清除 pending；图片异步准备和 SDK 提交固定使用请求开始时的 context。不可沿用首次 Main Ability 的 context 去拉起独立直播 Ability 的微信操作。

转账 `requested` 后释放发送槽，微信未登录或直接返回也不阻塞下次拉起。只保留最多 64 笔进程内回执关联，不持久恢复已受理转账；旧回执按 transaction/kind 校验，只交原请求，不清除后继请求。清除 store 失败仍保留原等待，避免未知持久状态被覆写。
