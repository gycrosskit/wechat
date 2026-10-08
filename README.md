# GY CrossKit Wechat

## 当前功能与平台边界

core 与原生client提供OAuth、图片/网页分享和商家转账确认页；无CMP UI，wechat-kuikly仅OHOS Module。当前候选iOS2.0.7支持指定联系人图片分享，OHOS1.0.23不支持。

适用版本：Maven 0.1.7；Swift Package / Git Pod native-0.1.6（Pod内部0.1.6）；HAR 0.1.6。本次修复与平台边界见[功能与平台差异](docs/功能与平台差异.md)，构建与渠道验收见[版本发布记录](https://github.com/gycrosskit/wechat/releases/tag/0.1.7)；下方旧版本记录保留其历史范围。

当前测试覆盖、执行时点和未验收项集中见[验证范围](docs/功能与平台差异.md#验证范围)，复现命令见[开发与验证](docs/开发与验证.md)。

native-0.1.5 已补齐 iOS 指定联系人图片分享，复用现用官方 SDK 2.0.7 的 `WXSceneSpecifiedSession` / `toUserOpenId` / `openID`。须同时提供当前 AppID 的可信接收者与发送者 openId；不降级为普通好友分享。已发布 `native-0.1.4` 不含此改动，详见 [本次修复验证](docs/指定联系人分享对齐.md)。

iOS 已发布：`GycWechatNative` Pod内部版本0.1.4，使用独立不可变Git标签 `native-0.1.4`。真实 Git Pod/UIKit App 链接与 Swift Package/device 编译通过，标签及实际编译源码一致。该原生标签仅包含当时Swift空白OAuth code修复；此段为native-0.1.4历史结果；当前版本组合见本页前部。详见[原生发布验收](docs/native-0.1.4发布验收.md)与[完整源码审查](docs/完整源码审查.md)。

微信 SDK 的 OAuth 授权、图片/网页分享和商家转账确认页入口，提供请求受理状态与 SDK 回执。账号换票、分享任务、订单查询及凭据由宿主负责；转账页面 `success` 不表示资金到账。

Maven **0.1.5** 已发布 [prerelease](https://github.com/gycrosskit/wechat/releases/tag/0.1.5)，修复 Android 后台入口、取消及迟回执归属；SDK、可信存储、状态和 listener 回调串行到 Main。Release 归档重下载 SHA 与 JitPack 全制品审计通过；精确合并提交、校验值、渠道限制及独立消费状态见[0.1.5 验收](docs/0.1.5远程发布验收.md)。该Maven发布当时未修改 OHOS 原生协议，配套 HAR 固定 **0.1.4**（旧 0.1.3 不支持取消 ack）；Swift Package / Git Pod 已发布 **native-0.1.4**（Pod内部0.1.4，真实远程消费见原生验收）；已验0.1.3保留历史记录。历史结果见[0.1.4 远程验收](docs/0.1.4远程发布验收.md)。

## 架构与调用流程

宿主在隐私准入后持有进程级原生 client，并转发官方 SDK 回跳；请求受理与业务回执分开。可信 pending 存储由宿主提供，不能从外部回跳重建授权资格。

```mermaid
flowchart TB
    H["宿主<br/>AppId / requestId / store / 回跳"] --> A["AndroidWechatClient<br/>Main 串行 SDK / Session / Store"]
    H --> I["IosWechatClient<br/>宿主 IosWechatBridge"]
    I --> S["Swift WechatClient<br/>WechatSession"]
    H --> K["WechatModule<br/>Kuikly Kotlin"]
    K --> R["WechatModule<br/>ArkTS Renderer"]
    R --> O["ArkTS WechatClient<br/>进程单例"]
    A --> SDK["各平台官方微信 SDK"]
    S --> SDK
    O --> SDK
    SDK -.-> E["回跳验证<br/>归一 WechatReceipt"]
    E -.-> H
```

下面是 Android OAuth 的关键流程；Android/OHOS 回执校验 transaction、kind 和 OAuth state。iOS OAuth 以 state 关联，分享没有 SDK transaction，只有本地单笔候选，不能沿用图中的 Android 归属证明。

```mermaid
sequenceDiagram
    participant H as 宿主
    participant C as Android client
    participant M as Android Main
    participant P as Session
    participant T as Store
    participant W as 微信 SDK
    H->>C: authorize(requestId)（任意线程）
    C->>M: Main 即时执行 / 后台排队
    M->>P: begin(id, token, state)
    P->>T: 同步原子 save(pending)
    T-->>P: 成功；失败则拒绝发送
    M->>W: registerApp / sendReq()
    M-->>H: onSubmitted(status)（Main）
    Note over H,W: REQUESTED 仅表示受理
    W-->>H: 官方回跳 Intent
    H->>C: handleIntent(rawIntent, callback)
    C->>M: 返回 SDK 真实处理结果（Main callback）
    W-->>C: onResp
    C->>P: consume(token, kind, state)
    P->>T: 同步 save(null)
    P-->>C: 匹配且清除后消费
    C-->>H: onReceipt(WechatReceipt)
    opt 宿主 cancel(requestId)
        H->>C: cancel(requestId)
        C->>M: queued 请求取消 / 清除可信 pending
        M-->>H: 清除成功后 CANCELLED
        Note over H,W: 取消本地等待<br/>无法关闭微信页面
    end
```

类型图聚焦 Kotlin Android 链路，`WechatSession` 是内部单笔 pending 状态；监听器分别接收受理与回执。iOS 已发送分享后取消会隔离该实例后续分享。Kuikly `dispose()` 移除页面监听和 callback，原生 client 仍为进程级实例；取消是否成功必须等待同版原生确认。

```mermaid
classDiagram
    class WechatClient {
        <<interface>>
        +authorize(requestId)
        +cancel(requestId)
    }
    class AndroidWechatClient {
        +handleIntent(intent) Boolean（仅 Main）
        +handleIntent(intent, callback)（任意线程）
        +attach(listener)
        +detach()
    }
    class WechatSession {
        <<internal>>
        +begin(id, token, kind, state)
        +consume(token, kind, state)
        +cancel(id) Boolean
    }
    class WechatRequestStore {
        <<interface>>
        +load()
        +save(request)
    }
    class WechatListener {
        <<interface>>
        +onSubmitted(requestId, status)
        +onReceipt(receipt)
    }
    class WechatReceipt
    WechatClient <|.. AndroidWechatClient
    AndroidWechatClient *-- WechatSession
    WechatSession --> WechatRequestStore : 可选可信存储
    AndroidWechatClient --> WechatListener : 主线程通知
    WechatListener ..> WechatReceipt
```

源码入口：[公共契约与回执](wechat-core/src/commonMain/kotlin/io/github/gycrosskit/wechat/WechatClient.kt)、[Android SDK 接线](wechat-core/src/androidMain/kotlin/io/github/gycrosskit/wechat/AndroidWechatClient.kt)、[Kotlin pending](wechat-core/src/commonMain/kotlin/io/github/gycrosskit/wechat/WechatSession.kt)、[iOS KMP 桥](wechat-core/src/iosMain/kotlin/io/github/gycrosskit/wechat/IosWechatClient.kt)、[Swift client](iosApp/Sources/GycWechatNative/WechatClient.swift)、[Swift 分享隔离](iosApp/Sources/GycWechatNative/WechatSession.swift)、[Kuikly 取消确认与 dispose](wechat-kuikly/src/commonMain/kotlin/io/github/gycrosskit/wechat/kuikly/WechatModule.kt)、[OHOS client](ohos/wechat-native/src/main/ets/WechatClient.ets)。指定联系人图片分享已在 Android 和当前 iOS 源码实现，OHOS 官方 SDK 1.0.23 未公开接收者字段，仍返回不支持；转账页回执不是到账证明。

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
        exclusiveContent {
            forRepository {
                maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-tencent/") }
            }
            filter { includeGroup("com.tencent.kuikly-open") }
        }
    }
}
// commonMain.dependencies
implementation("com.github.gycrosskit.wechat:wechat-core:0.1.7")
// OHOS Kuikly 宿主额外添加：
implementation("com.github.gycrosskit.wechat:wechat-kuikly:0.1.7")
```

iOS 选择 Git Pod，或 Xcode 的 Swift Package：

```ruby
pod 'GycWechatNative', :git => 'https://github.com/gycrosskit/wechat.git', :tag => 'native-0.1.6'
```

Swift Package URL 为 `https://github.com/gycrosskit/wechat.git`，固定 revision/tag 为 `native-0.1.6`，产品 `GycWechatNative`。Package 不包含微信 binaryTarget，宿主仍需提供并链接官方 XCFramework；Git Pod 会安装精确版本厂商依赖，未发布到 CocoaPods Specs。

HarmonyOS 此版使用 HAR `0.1.6`，精确 Registry 可安装性见顶部发布记录。Registry 审核通过前按 Release SHA 固定下载独立原生包，审核受理不等于已上架：

```sh
ohpm install @gycrosskit/wechat-native@0.1.6
```

[此版 Release](https://github.com/gycrosskit/wechat/releases/tag/0.1.7) 提供 HAR `0.1.6` 的 `WechatNative.har` 和 SHA-256，供校验及文件依赖使用；不要以旧 0.1.0 替代新增 API。

## 最小接入

Android 在隐私准入后构造并持有一个进程级客户端；构造及 Unit 入口允许后台调用，SDK 与 store 在 Main 懒初始化：

```kotlin
import io.github.gycrosskit.wechat.AndroidWechatClient
import io.github.gycrosskit.wechat.WechatScene

val client = AndroidWechatClient(application, appId, listener, trustedStore)
client.authorize(uniqueRequestId) // 返回不保证已发送；等待 Main onSubmitted(REQUESTED)。
// 普通好友分享；requestId 每次调用唯一，不复用。
client.shareImage(anotherUniqueRequestId, imageBytes, WechatScene.SESSION)
```

上述类型来自 `wechat-core`，完整包名、监听器、store 与平台示例见[接入指南](docs/接入指南.md)。宿主必须实现 `{applicationId}.wxapi.WXEntryActivity`，在 Main `onCreate/onNewIntent` 把原始 Intent 交给同一实例的同步 `handleIntent(intent): Boolean` 并结束 Activity；后台接入使用 `handleIntent(intent) { handled -> ... }`，callback 在 Main 返回 `Result<Boolean>`，成功值为真实 SDK Boolean，失败为异常；授权字段只能由官方 SDK 验证。还需配置 INTERNET、开放平台包名和签名。

iOS 持有唯一 `WechatClient`，把 URL Scheme / Universal Link 交给 `handleOpenURL` / `handleUniversalLink`；宿主配置 Info.plist、Associated Domains 与 AASA。KMP 使用导出的 `IosWechatBridge`，参考 [Swift 适配示例](iosApp/KmpWechatBridge.swift)。

OHOS 在 EntryAbility 配置 `WechatClient.configure(appId, context, trustedStore)` 并交回跳 Want；初始化前可调用 `forwardWant`。Kuikly 两端注册 `GycWechat` Module，页面释放时调用 `dispose()`，原生监听对应移除。

## 必须了解的边界

- Android 构造、授权、分享、转账、取消与 attach/detach 允许任意线程；主线程即时执行，后台排队，图片计算仍在专用 imageExecutor。Unit 返回不代表 SDK 受理；同步 Boolean `handleIntent` 仍限定 Main，兼容旧 false 表示未处理（含 SDK 异常），后台必须使用 callback 重载，不阻塞等待。
- Android Main 取消尚未执行的入队请求后，该请求不会打开微信。`cancel` 返回不保证清除；存储清除失败保留 pending/owner，不伪造 CANCELLED 或 FAILED 终态，未知 ID 不通知终态。无 owner 的回执支持晚监听；有 owner 的迟回执只交给同一 listener（detach 后重新 attach 也可回放），新 listener 不接旧 owner 结果。
- `REQUESTED` 只表示 SDK 受理。Android/OHOS 按 transaction、类型和 OAuth state 验证回执；iOS 分享没有 transaction，`requestId == nil`，`SINGLE_PENDING` 只是当前单笔任务的本地候选，不能当成 SDK 准确关联或资金凭据。
- iOS 分享在回执前保持 `BUSY`；SDK 已发送后取消，会隔离本实例后续分享并返回 `UNSUPPORTED`，防止迟回执误认。不得在同进程重建客户端绕过；OAuth 与转账仍可使用。
- 冷启动恢复需要宿主提供同步原子可信 store，发送前保存、消费/取消前清除。不能从 Intent/Want/URL 生成恢复记录；iOS 只恢复 OAuth。归一回执的迟监听缓存仅限当前进程，业务服务端仍需兜底。
- 图片最大 25 MiB，缩略图最大 32 KiB；Android 大于 10 MiB 需满足专用客户端版本门槛。指定联系人由 Android 和当前 iOS 源码支持，需同 App 可信接收者和发送者 openId；Android 保留 SDK 客户端版本门槛，iOS 使用官方场景及收件人字段并等待真实 SDK 受理/回执。OHOS 仍不支持，不降级普通好友；iOS 最低客户端条件及真实发送待设备验收。
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

## 自动回归

[Source regression](.github/workflows/regression.yml) 的当前工作树候选按事件分阶段：PR 先判断变更范围，仅源码变更运行已有 Android/Native 测试与编译；纯文档 PR 和 `main` push 只运行轻量脚本/配置检查。手动运行不填版本时执行源码回归，未知路径保守按源码处理。候选尚未合入，线上生效与耗时以实际 Actions 运行为准。

[Release validation](.github/workflows/release-validation.yml) 在 Maven Release 发布或手动填写精确已发布版本时，`verify-public` 统一校验一次冻结归档、精确 tag/commit、完整 publication 清单和公开文件；通过后 Android/Native 独立消费者从 JitPack 解析该版本。PR 不再反复消费旧基线；不使用 `mavenLocal`、本库源码或归档替换远程依赖。此流程不发布二进制。

GitHub-hosted runner 的实际结果以 Actions 为准；没有 DevEco/ohpm runner，因此 HAR 构建、ohpm Registry 安装、完整原生 SDK 集成和真机业务验收仍按既有验证文档执行，不能由这些 job 的成功代算。

阶段、缓存、有限网络重试、失败记录与证据边界见[共用 CI 规则](https://github.com/gycrosskit/.github/blob/main/docs/持续集成门禁.md)；本库实际平台命令以 workflow 为准。源码通过、远程消费、HAR/ohpm 与设备验收分别记录。

公网核验同步组织 `templates/check-public-maven.py`：使用冻结归档给出的完整 publications 清单，核对 JitPack tag/commit、每个公开 POM/Module、全部声明变体字节大小和四类哈希、内部精确版本及 `available-at`；MD5/SHA-1 sidecar 必须匹配。SHA-256/SHA-512 sidecar 的 HTTP 404 单独输出为渠道缺失，不计为校验通过。
