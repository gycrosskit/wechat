# GY CrossKit Wechat

微信 SDK 的 OAuth 授权、图片/网页分享和商家转账确认页入口，提供请求受理状态与 SDK 回执。账号换票、分享任务、订单查询及凭据由宿主负责；转账页面 `success` 不表示资金到账。

本轮 Maven / Swift Package / Git Pod / HAR 预发布为 **0.1.3**。实际远程消费见[闭合验收](docs/远程闭合验收.md)；旧 HAR **0.1.1** 已正式上架，不能以旧 Registry 代替候选 pending 存储 API。

## 支持范围

| 入口 | 平台要求 | 厂商依赖 |
| --- | --- | --- |
| `wechat-core` | Android API 24；iOS 15；OHOS KMP 桥 | Android 微信 SDK 6.8.34；iOS 使用原生桥 |
| `GycWechatNative` | iOS 15，Swift / Git Pod | WechatOpenSDK-XCFramework 2.0.7 |
| `@gycrosskit/wechat-native` | HarmonyOS API 22 | @tencent/wechat_open_sdk 1.0.23 |
| `wechat-kuikly` | OHOS Kuikly Module | Kuikly core 2.28.0-2.0.21-ohos、render 2.28.0 |

KMP 使用 Kotlin **2.2.21-1.0.0** OHOS 工具链。KMP 产物和 HAR 是独立渠道；KMP 依赖不能代替原生 SDK 注册、回跳与签名配置。

## 安装

Gradle 仓库与依赖：

```kotlin
// settings.gradle.kts：保留已有 google() / mavenCentral()
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io") { content { includeGroup("com.github.gycrosskit.wechat") } }
        maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
        maven("https://mirrors.tencent.com/nexus/repository/maven-public/")
    }
}
// commonMain.dependencies
implementation("com.github.gycrosskit.wechat:wechat-core:0.1.3")
// OHOS Kuikly 宿主额外添加：
implementation("com.github.gycrosskit.wechat:wechat-kuikly:0.1.3")
```

iOS 选择 Git Pod，或 Xcode 的 Swift Package：

```ruby
pod 'GycWechatNative', :git => 'https://github.com/gycrosskit/wechat.git', :tag => '0.1.3'
```

Swift Package URL 为 `https://github.com/gycrosskit/wechat.git`，精确版本 `0.1.3`，产品 `GycWechatNative`。Package 不包含微信 binaryTarget，宿主仍需提供并链接官方 XCFramework；Git Pod 会安装精确版本厂商依赖，未发布到 CocoaPods Specs。

HarmonyOS 新版仍在 OHPM `next` 审核，精确 Registry 安装尚未通过；以下命令仅在审核上架后使用。审核期间可按 Release SHA 固定下载独立原生包：

```sh
ohpm install @gycrosskit/wechat-native@0.1.3
```

[Release](https://github.com/gycrosskit/wechat/releases/tag/0.1.3) 同时提供 `WechatNative.har` 和 SHA-256，供校验及文件依赖使用；不要以旧 0.1.0 替代新增 API。

## 最小接入

Android 在隐私准入后于主线程构造并持有一个进程级客户端：

```kotlin
import io.github.gycrosskit.wechat.AndroidWechatClient
import io.github.gycrosskit.wechat.WechatScene

val client = AndroidWechatClient(application, appId, listener, trustedStore)
client.authorize(uniqueRequestId)
// 普通好友分享；requestId 每次调用唯一，不复用。
client.shareImage(anotherUniqueRequestId, imageBytes, WechatScene.SESSION)
```

上述类型来自 `wechat-core`，完整包名、监听器、store 与平台示例见[接入指南](docs/接入指南.md)。宿主必须实现 `{applicationId}.wxapi.WXEntryActivity`，在 `onCreate/onNewIntent` 把原始 Intent 交给同一实例的 `handleIntent` 并结束 Activity；授权字段只能由官方 SDK 验证。还需配置 INTERNET、开放平台包名和签名。

iOS 持有唯一 `WechatClient`，把 URL Scheme / Universal Link 交给 `handleOpenURL` / `handleUniversalLink`；宿主配置 Info.plist、Associated Domains 与 AASA。KMP 使用导出的 `IosWechatBridge`，参考 [Swift 适配示例](iosApp/KmpWechatBridge.swift)。

OHOS 在 EntryAbility 配置 `WechatClient.configure(appId, context, trustedStore)` 并交回跳 Want；初始化前可调用 `forwardWant`。Kuikly 两端注册 `GycWechat` Module，页面释放时调用 `dispose()`，原生监听对应移除。

## 必须了解的边界

- `REQUESTED` 只表示 SDK 受理。Android/OHOS 按 transaction、类型和 OAuth state 验证回执；iOS 分享没有 transaction，`requestId == nil`，`SINGLE_PENDING` 只是当前单笔任务的本地候选，不能当成 SDK 准确关联或资金凭据。
- iOS 分享在回执前保持 `BUSY`；SDK 已发送后取消，会隔离本实例后续分享并返回 `UNSUPPORTED`，防止迟回执误认。不得在同进程重建客户端绕过；OAuth 与转账仍可使用。
- 冷启动恢复需要宿主提供同步原子可信 store，发送前保存、消费/取消前清除。不能从 Intent/Want/URL 生成恢复记录；iOS 只恢复 OAuth。归一回执的迟监听缓存仅限当前进程，业务服务端仍需兜底。
- 图片最大 25 MiB，缩略图最大 32 KiB；Android 大于 10 MiB 需满足专用客户端版本门槛。指定联系人仅 Android 支持，需同 App 可信接收者和发送者 openId 及 SDK 版本门槛；iOS/OHOS 返回不支持，不降级普通好友。
- 凭据、state、Code、原始回跳与商户参数不得写入日志。`cancel` 只能结束本地等待；库不实现普通 `PayReq` APP 支付。

各平台的存储失败、取消、图片资源及重复回执处理详见接入指南。实际微信客户端、签名回跳、Universal Link 与转账兼容性需要设备验收，编译通过不代表业务成功。

## 文档与反馈

- [接入指南](docs/接入指南.md)：平台接线、回执归属、冷启动恢复与分享契约。
- [开发与验证](docs/开发与验证.md) · [验证记录](VALIDATION.md)。
- [Releases](https://github.com/gycrosskit/wechat/releases) · [Issues](https://github.com/gycrosskit/wechat/issues)：附版本、平台和脱敏复现步骤。

由 GY CrossKit 维护，采用 [Apache-2.0](LICENSE)；厂商 SDK 适用其自身许可与隐私政策。

## OHOS pending 存储（0.1.3）

组件提供 `WechatPreferencesRequestStore(appId, context, namespace)`，默认 namespace 为 `wechat_pending_${appId}`，兼容旧宿主 `pending` 字段。

```typescript
const store = new WechatPreferencesRequestStore(appId, context);
const restored = store.load(); // 业务恢复资格由宿主判断
const client = WechatClient.configure(appId, context, store);
```

同步 flush 失败抛异常，SDK发送前不能吞掉；不会从外部 Want 构造可信记录。`configure` 未显式提供 store 时仍维持原进程内语义。
Node替身检查覆盖旧namespace、重启/隔离、删除与落盘失败；不代表真实设备磁盘或微信已验收。
