# GY CrossKit Wechat

微信 SDK 注册与回跳入口，提供 OAuth 授权、图片/网页好友或朋友圈分享、商家转账确认页拉起。仅返回 SDK 请求受理、授权 Code 与页面回执；`pageResult=success` 表示确认页展示成功，资金状态由宿主服务端核实。

Maven `0.1.1` 已发布：[GitHub Release](https://github.com/gycrosskit/wechat/releases/tag/0.1.1)，JitPack 状态 `ok`，独立消费的Android、iOS Simulator Framework 链接、OHOS 编译通过。 HAR `0.1.0` 已提交 OHPM 审核，尚未上架；GitHub Release HAR 已远程下载、SHA-256 校验、安装到独立工程并 assembleHar 成功。OHPM 不支持此 HAR URL 直接依赖，验收使用下载缓存的 file 依赖，不计为 Registry 安装验收。 Swift Package 从远程 Git 标签 `0.1.0` 拉取，提供官方 WechatOpenSDK-XCFramework 2.0.7 的 Simulator slice 后 xcodebuild 成功；未上传 CocoaPods Specs。

## 平台与依赖

| 入口 | 实现与最低版本 | 外部 SDK |
| --- | --- | --- |
| `wechat-core` Android | API 24，KMP `WechatClient` | `com.tencent.mm.opensdk:wechat-sdk-android:6.8.34` |
| `wechat-core` iOS | iOS 15，`IosWechatBridge` / `IosWechatClient` | 宿主连接下述原生包 |
| Swift `GycWechatNative` | iOS 15，`WechatClient`，一个 `WXApiDelegate` | CocoaPods `WechatOpenSDK-XCFramework` **2.0.7** |
| HAR `@gycrosskit/wechat-native` | HarmonyOS API 22 构建，原生 Promise API | `@tencent/wechat_open_sdk` **1.0.23** |
| `wechat-kuikly` | OHOS Kuikly Module `GycWechat` | Kotlin **2.2.21-1.0.0**、Kuikly core **2.28.0-2.0.21-ohos**、render **2.28.0** |

图片输入最大 10 MiB，缩略图下采样后最大 32 KiB。Android/iOS 使用图片字节；OHOS 原生接口使用纯 Base64，不支持 data URL。OHOS 图片分享只接受 PNG/JPEG。所有端仅支持普通好友会话和朋友圈，不提供指定联系人。纯 OpenHarmony、模拟器没有微信客户端时不能完成实际授权和分享。

商家转账 Android 依照官方文档检查 `wxAppSupportAPI >= 0x28002d33`，客户端至少微信 8.0.45.51；iOS 官方最低微信 8.0.45，但通用 `isWXAppSupport()` 无法判断这一专用版本，必须以页面回执为准。OHOS SDK 1.0.23 有 `OpenBusinessViewReq`，可构建对应请求；尚未验证微信设备上该业务的兼容性，因此不承诺具体最低微信版本。

SDK 二进制、AppID、Universal Link、签名、商户凭据均由宿主提供，不进入库源码。库为 Apache-2.0；厂商 SDK 适用其自身授权与隐私政策。

## 请求与回调边界

`WechatListener.onSubmitted(requestId, status)` 表示发送受理；`REQUESTED` 不表示最终分享、登录或转账成功。`onReceipt(WechatReceipt)` 保留 SDK `errorCode`、授权 Code 或页面 `result`。宿主不得记录 Code、state、package、原始回跳 URL 或 SDK 原始错误文本。

- Android/OHOS 每个进程级实例同时等待一笔请求；新请求返回 `BUSY`。内部随机 `transaction` 与请求类型精确匹配，OAuth 成功、取消和失败均严格匹配安全随机 state。重复和已取消请求的迟到回执被忽略。
- iOS 只有 OAuth 带 state；分享/转账 SDK 2.0.7 的 `BaseResp` 没有 `transaction`。这两类回执 **`requestId == nil`**，不能认定为某一笔请求完成。SDK send completion 自己有 requestId；发送期间或 OAuth 等待期间返回 busy，share/transfer 受理后即可发下一笔，后续 SDK 回执仍完全不关联。重复 URL/Universal Link 以 SHA-256 摘要去重；不同回跳若内容不同，仍可能产生无法归属的页面回执，业务不能据此触发任务或资金动作。
- `cancel` 只结束库的本地等待，无法关闭微信页面。无 state 的老 SDK 授权回调被忽略，宿主可以在超时/页面离开时取消。宿主为每次调用生成不可复用的 requestId（最长 128 字符），库在实例生命周期内保留已使用 ID。
- 图片准备期间也占用请求槽位。Android Bitmap、iOS ImageIO 图像为内存数据；OHOS 图片文件保留至当前进程精确匹配的回执、发送失败或取消；进程被终止后原缓存文件由宿主缓存清理策略回收，恢复记录不保存文件路径，文件、ImageSource、PixelMap、ImagePacker 分别释放。页面销毁需调用 Kuikly `dispose()`；原生监听需对应移除并取消自己的请求。
- 回执可能早于异步 send completion 到达；宿主不应以“尚未收到 REQUESTED”为理由丢弃已严格校验的授权回执。

没有业务登录换票、roomId、分享任务完成、订单查询、业务文案和隐私授权流程。未实现普通 `PayReq` APP 支付。

## 可信冷启动恢复与迟挂监听

Android 构造参数 `store: WechatRequestStore?`、OHOS `configure(appId, context, store)` 和 iOS `store: WechatAuthorizationStore?` 均可选。没有 store 只支持当前进程请求。store 是宿主在隐私授权后提供的同步、原子持久存储，同一 App 只允许一个进程级客户端读写；读取错误不可降级为从回跳猜测请求。

- Android/KMP 记录 `WechatPendingRequest(requestId, transaction, kind, state)`；OHOS 同名结构的 `kind` 为 `authorization / share / merchant_transfer`，非 OAuth 的 `state` 为 `''`。transaction/state 由组件生成，发送 SDK **之前**写入；不能从 Intent、Want、回跳 URL 或 Kuikly 页面传入恢复快照。
- 消费、发送失败、取消先同步 `save(null)`，再结束等待或交付归一结果。宿主必须真正删除持久记录、禁止旧备份重放，并按账号/AppID 隔离、保护 OAuth state；不要记录其中的敏感字段。写入失败不会发送；清除失败不会交付，并需宿主修复存储后取消等待（Android/OHOS 可重新交 SDK 校验回跳）。
- 进程重建时先从 store 恢复等待，再将原始回跳交 `handleIntent` / `handleWant` / iOS 官方入口。只有 SDK 校验产生的响应，transaction、类型及 OAuth state 全部精确匹配时才消费；未知、类型错误、缺失/错误 state 和重复响应均拒绝。恢复本身不会发出 `REQUESTED`、不会再次发送请求；等待期间新请求仍 `BUSY`。
- Android `attach(listener)` / `detach()`，Swift `attach { receipt in }` / `detach()`，OHOS `addListener` / `removeListener` 支持迟挂监听。已归一回执只在本进程缓存（最多 64 笔），取出后不重放；取消同一 requestId 也会删除尚未交付的缓存。再次进程退出会丢失此缓存：本版本不承诺跨进程业务结果可靠投递，宿主用业务服务端核验兜底。
- OHOS Kuikly `attach(listener, restoredRequestId)` 只认领客户端已有的可信等待或归一缓存，不能导入 transaction/state。其他页面监听不会拿走此回执。页面 `dispose()` / native `onDestroy()` 取消其拥有的请求并释放监听；销毁后的页面不能复活请求。
- iOS 仅持久恢复 OAuth 的 `WechatPendingAuthorization(requestID, state)`。SDK `BaseResp` 没有 transaction，分享/转账继续返回 `requestID == nil`，无法按 requestId 取消或关联这类回执；不能用恢复记录伪造关联，也不能据此标记资金到账。

例如 OHOS 宿主的 `trustedStore` 实现 `load(): WechatPendingRequest | null` 与 `save(request: WechatPendingRequest | null): void`；同步持久化和错误处理由现有宿主存储能力完成。先 `forwardWant`、后 `configure(..., trustedStore)`、再 Kuikly `attach(listener, restoredRequestId)` 即覆盖冷启动迟监听链路。

## Android 与 KMP 接入

远程 Maven 坐标（JitPack）：

```kotlin
implementation("com.github.gycrosskit.wechat:wechat-core:0.1.1")
// OHOS Kuikly 消费者额外添加：
implementation("com.github.gycrosskit.wechat:wechat-kuikly:0.1.1")
```

宿主在隐私授权后于主线程构造并持有唯一 `AndroidWechatClient(application, appId, listener, trustedStore)`。授权调用 `authorize(requestId)`；网页分享调用 `shareWebPage(requestId, url, title, description, thumbnailBytes, WechatScene.SESSION)`；转账参数全部来自服务端并原样传入 `openMerchantTransfer`。

**宿主必须自行实现 `{applicationId}.wxapi.WXEntryActivity`**。Activity 的 `onCreate` 与 `onNewIntent` 将 Intent 交给同一实例的 `handleIntent(intent)`，随后 `finish()`；不要直接读取 Intent 中的授权或转账字段，也不要创建第二个 SDK 实例。回跳期间 Application 冷启动仍要先接线；传入可信 `WechatRequestStore` 时构造即恢复；没有恢复记录的旧回执仍被丢弃。

宿主 Manifest：

```xml
<activity android:name=".wxapi.WXEntryActivity"
    android:exported="true"
    android:launchMode="singleTask"
    android:theme="@android:style/Theme.Translucent.NoTitleBar" />
```

宿主配置 INTERNET 权限及微信开放平台的包名和签名。库 Manifest 仅合并 `queries/com.tencent.mm` 包可见性，固定 Activity 名称与签名不由库猜测。SDK 的 Intent 验签仍由官方 `handleIntent` 完成。

## iOS 原生与 KMP 接入

原生包可用根 `GycWechatNative.podspec`（本地 Pod `:path => '../wechat'`），它通过外部 CocoaPods 依赖精确版本 2.0.7。也可用本地 Swift Package 产品 `GycWechatNative`；Swift Package 不提供厂商 binaryTarget，宿主必须将官方 XCFramework 的目标平台 slice 加入 Swift/Framework 搜索路径并链接（CocoaPods 可自动管理）。单独添加此 Swift Package、未接线 WechatOpenSDK 时无法编译。

```swift
import GycWechatNative
// 主线程、隐私授权后，在 App 级容器中持有唯一实例：
let wechat = WechatClient(appID: hostAppID, universalLink: hostUniversalLink,
    onSubmitted: { requestID, status in /* 请求受理 */ },
    onReceipt: { receipt in /* Code 或 SDK 页面回执 */ })
```

`status` 为 `requested / busy / not_installed / unsupported / invalid_content / failed / cancelled`。UIApplicationDelegate/SwiftUI 把 URL Scheme 和 Universal Link 分别交给 `handleOpenURL` 和 `handleUniversalLink`。Info.plist 的 AppID URL Scheme、`LSApplicationQueriesSchemes`（`weixin`、`weixinULAPI`）、Associated Domains、Universal Link 域名服务端 AASA 与开放平台配置均由宿主负责。将授权 Code 返回宿主后不等待 UIApplication 激活，不额外保存凭据。

KMP 宿主实现导出的 `IosWechatBridge`，委托给原生 `WechatClient`，再创建 `IosWechatClient(bridge)`。完整适配示例为 `iosApp/KmpWechatBridge.swift`（构造时可传原生 `WechatAuthorizationStore`），当前示例用 framework 名 `WechatCore`；实际宿主改为其导出的 framework 名。示例已对真实生成的 KMP framework typecheck。

## HarmonyOS 与 Kuikly

HAR 包名 `@gycrosskit/wechat-native@0.1.0`，已提交 OHPM 审核；上架前可下载不可变 GitHub Release 的 HAR 并校验 SHA-256，正式 OHPM 坐标待上架安装验收。

```typescript
import { WechatClient } from '@gycrosskit/wechat-native';
// 隐私授权后，EntryAbility 先注册，再交回跳 Want 给官方 SDK：
const client = WechatClient.configure(hostAppId, context, trustedStore);
client.handleWant(want);
client.addListener(onReceipt);
const status = await client.authorize(uniqueRequestId);
// 页面结束：client.cancel(uniqueRequestId); client.removeListener(onReceipt);
```

EntryAbility `onCreate`、`onNewWant` 共用此入口。配置尚未完成时调用 `WechatClient.forwardWant(want)`，最多暂存 4 个 Want；配置完成后仍逐个交官方 SDK 验证。Bundle Name、identifier、签名指纹、官方回跳 schemes/skills 和微信开放平台审核均由宿主接线；库不解析 Want 的授权字段、不配置虚构的签名。未注册时不可使用 Kuikly Module；注册发生在宿主层，不从页面 JSON 信任 AppID。

Kotlin Pager 注册 `WechatModule.NAME to WechatModule()`，调用 `attach(listener)`；冷启动页面用 `attach(listener, restoredRequestId)` 认领宿主记录中的请求；ArkTS render 注册 `WechatModule.MODULE_NAME` 对应 `WechatModule`。两端 Module 名都是 `GycWechat`。页面销毁调用 Kotlin `dispose()`，取消本页面拥有的请求并释放 persistent callback。原生全局 SDK 不随 Kuikly 页面销毁。

## 本地验证

使用 JDK 21，`ANDROID_HOME` 指向本机 Android SDK。构建时固定 `--max-workers=1`，没有真实微信操作。

```sh
bash gradlew :wechat-core:compileDebugKotlinAndroid :wechat-core:jvmTest \
  :wechat-core:linkDebugFrameworkIosSimulatorArm64 :wechat-core:compileKotlinOhosArm64 \
  :wechat-kuikly:compileKotlinOhosArm64 --max-workers=1 --no-daemon
node tests/wechat.cjs
xcrun swiftc iosApp/Sources/GycWechatNative/WechatSession.swift verification/swift/main.swift -o build/swift-check
build/swift-check
# 构建源码为本地 Maven 文件仓库，仅供独立消费者验证：
bash gradlew :wechat-core:publishToMavenLocal :wechat-kuikly:publishToMavenLocal \
  -Dmaven.repo.local="$PWD/verification/maven" --max-workers=1 --no-daemon
bash gradlew -p verification/gradle -PwechatMavenRepo="$PWD/verification/maven" \
  compileDebugKotlinAndroid linkDebugFrameworkIosSimulatorArm64 compileKotlinOhosArm64 \
  --max-workers=1 --no-daemon
# DevEco 环境：
cd ohos && ohpm install --all
hvigorw --mode module -p module=WechatNative@default -p product=default assembleHar --no-daemon
```

Swift Package 构建需向 `xcodebuild` 提供对应官方 XCFramework slice 的 `FRAMEWORK_SEARCH_PATHS` 和 `OTHER_SWIFT_FLAGS='-F <slice-directory>'`，使用 `-jobs 1 CODE_SIGNING_ALLOWED=NO`。独立 Swift consumer 位于 `verification/swift-consumer`；独立 HAR consumer 位于 `verification/ohos`，安装生产出来的本地 HAR，再 `assembleHar`。

实际结果见 [VALIDATION.md](VALIDATION.md)。真实客户端安装/未安装、OAuth 返回、好友/朋友圈 UI、Universal Link 和 OHOS 签名回跳均未做设备验收；没有真实登录、支付、转账或发送分享。

## 官方依据与来源

通用实现依据 sxmqliveAndroid `codex/harmony-production-integration` 的 Android WechatGateway/WechatCallback、AuthPlatform 的 OAuth state、iOS Auth/WechatSdkBridge 和 OHOS Wechat/AuthModule 提取；业务依赖全部移除。

本轮检索核实官方 [Android 商家转账](https://pay.wechatpay.cn/doc/v3/merchant/4012719576)、[iOS 商家转账](https://pay.wechatpay.cn/doc/v3/merchant/4012719578) 与 [转账参数常见问题](https://pay.wechatpay.cn/doc/v3/merchant/4013778940)：SDK 最低版本、Android 版本门槛、业务类型、参数原样 URL 编码、页面回执非资金终态。

微信开放平台 [Android 接入](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/Android.html)、[iOS 接入](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/iOS.html)、[OHOS 接入](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/ohos.html) 和 [OAuth 指引](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html) 已尝试读取，本轮浏览工具未成功取得正文；OAuth 字段和 iOS 无 transaction 边界以安装的官方 SDK 2.0.7 Header、Android 6.8.34 和 OHOS 1.0.23 API 及实际编译核对，完整宿主接线仍需依照开放平台最新配置验收。

## 发布准备

`jitpack-install.sh`、`jitpack-metadata.py` 使用 GY CrossKit 共用的不可变 Release Maven 归档模板；`jitpack.yml` 调用 `bash jitpack-install.sh wechat`。`release-checksums.txt` 已记录不可变 Maven 标签归档的 SHA-256；`release-pack.py` 排除 macOS AppleDouble，防止 Linux 把扩展属性文件当成 metadata。远程 Maven、Swift Package 与 GitHub Release HAR 消费通过，OHPM 审核后仍需 Registry 安装验收。
