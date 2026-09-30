# 本地验证记录

日期：2026-09-30。工作目录 `/Users/guoyang/gycrosskit/.worktrees/issues-six/wechat`，分支 `codex/wechat-contract-fix`，原始源码基线 `529e9b7`。本轮未提交、推送、创建标签或发布；原始共享目录只读。

| 验证 | 结果 | 说明 |
| --- | --- | --- |
| Android `:wechat-core:compileDebugKotlinAndroid` | 通过 | 真实 `wechat-sdk-android:6.8.34`，恢复存储与迟监听 API |
| `:wechat-core:jvmTest` | 通过 | 共用 session 三个测试：transaction/type/state、BUSY、一次消费、持久记录进程重建、取消、存储失败拒绝发送/消费 |
| KMP iOS Simulator framework | 通过 | `linkDebugFrameworkIosSimulatorArm64`，真实 Kotlin/Native |
| KMP OHOS | 通过 | core、Kuikly `compileKotlinOhosArm64`，真实 Kotlin/Native |
| Swift 原生产品 | 通过 | 官方外部 WechatOpenSDK XCFramework 2.0.7，Simulator arm64/x86_64 编译链接；独立消费重编最终修改 |
| KMP Swift 适配 | 通过 | `KmpWechatBridge.swift` 对真实 WechatCore framework 和最终 GycWechatNative module typecheck，包含 store 参数 |
| Swift session self-check | 通过 | OAuth state、BUSY、重复/迟到、可信日志进程重建、取消、日志读取失败 |
| OHOS `WechatNative assembleHar` | 通过 | 真实 SDK 1.0.23、Kuikly render 2.28.0、API22；最终变更重建 |
| `node tests/wechat.cjs` | 通过 | 实际 ArkTS 转译代码，SDK/文件/图像 API 为 mock；进程隔离重建、先 Want 后初始化、官方校验入口拒绝未验证 Want、精准 transaction/type/state、迟挂 Kuikly、其他页面不吞回执、销毁/取消、重复重放、转账页面 result、临时文件与资源释放 |
| 本地 Maven staging | 通过 | `publishToMavenLocal` 指定 `verification/maven`，两个模块所有已声明变体；9 个 Module Metadata / 23 个文件引用存在 |
| 独立 Gradle Android/OHOS 消费 | 通过 | 默认 JitPack，属性 `wechatMavenRepo` 指定 staging；无 includeBuild/project 依赖；恢复公共 API 编译 |
| 独立 Gradle iOS Simulator 消费 | 通过 | 使用相同 staging 的真正 KLIB 消费 |
| 独立 Swift Package 消费 | 通过 | `verification/swift-consumer` 与真实 SDK 编译链接 |
| 独立 HAR 消费 | 通过 | 安装产出的本地 HAR 后 `Consumer assembleHar`；包含公开 store API |
| `ohpm prepublish <HAR>` | 通过 | 仅本地发布检查；源码 HAR 有公开源码警告，未执行 publish |
| `git diff --check` | 通过 | 未修改无关文件或生成产物 |

Gradle 使用 JDK21、Xmx2g、`--max-workers=1 --no-daemon`；Native 链接与其它组件错峰，没有根 build/check/clean。Swift `-jobs 1 CODE_SIGNING_ALLOWED=NO`。初次 Xcode 自动 scheme 尚未生成导致失败，执行 `xcodebuild -list` 后重跑通过；第一次 prepublish 漏传 HAR 路径，修正后通过；一次 HAR 日志重定向目录错误，未执行构建，纠正工作目录后重跑。

HAR 有外部 Kuikly strict-typing、packing deprecation、设备系统能力及 hvigor SemVer 警告，实际 manifest 为 `0.1.0`，ohpm prepublish 校验通过。本地消费 HAR 的本地路径警告符合验证用途。

首发 staging：`build/release/wechat-maven.tar.gz`（由 `verification/maven/com` 打包），`build/release/WechatNative.har` 及各自 SHA-256 文件。源码版本、Podspec 和 HAR 均为 `0.1.0`；标签归档/JitPack 校验文件和远程消费由正式发布步骤完成，不能把本地 staging 写成远程已发布。

未验证：真实客户端安装/版本分支、实际 OAuth 返回、Android 签名/固定 Activity、iOS URL Scheme/Universal Link、OHOS 签名回跳、好友/朋友圈界面、转账确认页展示、远程 Maven/Swift/ohpm 下载。没有真实登录、支付、转账或分享发送。mock 验证不能代替 SDK 验签真机验收；转账 pageResult success 不代表资金到账。

## 2026-09-30 远程发布修正

Maven 候选改为 0.1.1，组件逻辑不变。JitPack Linux 实际错误为将 macOS AppleDouble `._*.module` 读取为 JSON。`release-pack.py` 用 Python tarfile 打包当前版本，排除 AppleDouble；归档逐项 JSON 与文件引用校验通过。旧 Release/标签不覆盖。重新发布全部声明平台产物成功，远程消费继续验证。

HAR 的 OHPM 版本保持原版本；Registry 要求的作者 URL、仓库 URL 与安装命令已补齐（如适用）。提交已被 Registry 接受，审核中；尚不能称为上架或远程安装成功。

## 2026-09-30 远程验收结果

Maven `0.1.1` 已发布：[GitHub Release](https://github.com/gycrosskit/wechat/releases/tag/0.1.1)，JitPack 状态 `ok`，独立消费的Android、iOS Simulator Framework 链接、OHOS 编译通过。 HAR `0.1.0` 已提交 OHPM 审核，尚未上架；GitHub Release HAR 已远程下载、SHA-256 校验、安装到独立工程并 assembleHar 成功。OHPM 不支持此 HAR URL 直接依赖，验收使用下载缓存的 file 依赖，不计为 Registry 安装验收。 Swift Package 从远程 Git 标签 `0.1.0` 拉取，提供官方 WechatOpenSDK-XCFramework 2.0.7 的 Simulator slice 后 xcodebuild 成功；未上传 CocoaPods Specs。

本轮默认远程仓库解析，无源码 include/project 替换或 mavenLocal。Gradle 消费使用 `--rerun-tasks` 强制编译；permission、diagnostics 同时刷新依赖，其余库使用新版本首次远程解析，`--info` 留有 JitPack 下载证据。行为测试、SDK mock 与产物消费不代表真机系统页面或真实授权/支付验收。
