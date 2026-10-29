# GY CrossKit Wechat Native

本包版本为 **1.1.0**，配套 Maven（core/Kuikly）`1.1.0` 和 iOS Git Pod/SPM `native-1.1.0`。HAR Release、OHPM 提交审核、Registry 安装和设备业务分别验收；源码版本声明不代表公开渠道已可用。

HarmonyOS 微信授权、图片/网页分享与商家转账确认页入口，依赖 `@tencent/wechat_open_sdk` `1.0.23`、Kuikly Renderer `2.29.1`，要求 API 22。

登录、分享、转账按类型管理当前轮，图片与网页共用分享轮。同类型新请求替换旧轮，跨类型互不等待；迟到回执、取消及重入只处理原请求归属。通用提交等待、回执投影、Base64 入口与 OHOS 监听恢复由组件提供。

```sh
# 仅 Registry 精确版本已上架、可安装后使用。
ohpm install @gycrosskit/wechat-native@1.1.0
```

审核期间可从精确 [HAR Release](https://github.com/gycrosskit/wechat/releases/tag/har-1.1.0) 下载 `WechatNative.har`，核对 `har-release-checksums.txt` 中的冻结摘要后安装；Release HAR 消费不能代替 Registry 上架和安装验收。正式提交通过受控发布器执行，版本标签和请求未知状态按[共用发布流程](https://github.com/gycrosskit/.github/blob/main/docs/发布流程.md)处理。

在 EntryAbility 配置唯一 `WechatClient` 并转交 Want；初始化前可调用 `forwardWant`。恢复使用宿主同步原子可信 `WechatRequestStore`，不能从页面或回跳恢复 transaction/state；监听与页面结束需成对取消、移除和 dispose。

普通图片分享在 SDK 受理后释放提交占用，不产生业务分享回执。文件在已交 SDK 后保留至精确匹配的图片回执；缺回执时等待系统缓存清理，不通过取消或定时器提前删除。

图片使用纯 Base64 PNG/JPEG，最大 25 MiB；指定联系人返回 `unsupported`，不降级普通好友。`requested` 不表示业务成功，转账页面回执不表示到账。

完整 API、接线和许可见[仓库 README](https://github.com/gycrosskit/wechat/blob/har-1.1.0/README.md)。

## 请求与回执归属

以下合同适用于本包；发布、Registry 审核和实际安装/编译分别验收。

多 Ability 宿主须在每次操作前，以实际前台调用方的 `UIAbilityContext` 再次 `configure`。同 AppID 只更新后继请求的 context，不创建第二 SDK、不清除 pending；图片异步准备和 SDK 提交固定使用请求开始时的 context。不可沿用首次 Main Ability 的 context 去拉起独立直播 Ability 的微信操作。

转账 `requested` 后释放发送槽，微信未登录或直接返回也不阻塞下次拉起。只保留最多 64 笔进程内回执关联，不持久恢复已受理转账；旧回执按 transaction/kind 校验，只交原请求，不清除后继请求。清除 store 失败仍保留原等待，避免未知持久状态被覆写。
