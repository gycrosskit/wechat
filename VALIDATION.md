# 本地验证记录

日期：2026-09-30。独立目录 `/Users/guoyang/gycrosskit/wechat`，未创建 Git 提交、远程仓库、标签或发布。源码来源目录只读。

| 验证 | 最终结果 | 说明 |
| --- | --- | --- |
| Android `:wechat-core:compileDebugKotlinAndroid` | 通过 | 真 SDK `wechat-sdk-android:6.8.34`，API 36 编译/minSdk24 |
| `:wechat-core:jvmTest` | 通过 | 真共用 WechatSession，安全 state、transaction、并发 busy、一次消费、取消/迟到/ID 复用 |
| KMP `linkDebugFrameworkIosSimulatorArm64` | 通过 | 真 Kotlin/Native Simulator framework |
| KMP `compileKotlinOhosArm64` | 通过 | core 与 Kuikly bridge，真 OHOS Kotlin/Native 编译 |
| iOS 原生 Swift Package `xcodebuild` | 通过 | 官方外部 WechatOpenSDK XCFramework 2.0.7，arm64/x86_64 Simulator 编译链接，无签名 |
| KMP Swift 适配 `KmpWechatBridge.swift` | 通过 | 对实际 WechatCore.framework 和 GycWechatNative.swiftmodule typecheck |
| Swift `WechatSession` self-check | 通过 | 状态匹配、伪造/缺失 state、并发、重复回调、取消后迟到发送完成 |
| OHOS `WechatNative assembleHar` | 通过 | 官方外部 `@tencent/wechat_open_sdk:1.0.23`，DevEco API22 |
| `node tests/wechat.cjs` | 通过 | 实际 ArkTS 转译代码，SDK/文件/图像 API 使用异步桩；安全 state、transaction、并发、重复/迟到、URL 及输入拒绝、参数原样编码、部分写入、图片临时文件/原生资源释放 |
| 独立 Gradle 消费 | 通过 | 不使用 includeBuild/project 依赖，安装本地产出的 Maven 坐标；Android 编译、iOS Simulator framework 链接、OHOS KLIB 编译 |
| 独立 Swift Package 消费 | 通过 | `verification/swift-consumer` 单独 package 依赖本地产品，对真实外部 SDK 构建 |
| 独立 HAR 消费 | 通过 | `verification/ohos` 安装产出的 WechatNative.har 再 assembleHar，不依赖生产目录源码 |

Gradle 使用 JDK21 和 `--max-workers=1 --no-daemon`；Native 与其它组件错峰。没有根 build/check/clean，也没有实际调用授权、支付、转账或分享发送。

初次 Android 构建因系统 Android Studio JDK25 与 Gradle 不兼容失败，改用 JDK21 后通过；HAR 初次编译发现 ArkTS 不支持 constructor parameter property，改为显式字段后通过；独立 Android 消费发现公开 IWXAPIEventHandler 继承导致 SDK implementation 不在消费编译 classpath，改为私有 handler 后重新产出和消费通过。

HAR 有外部 Kuikly 类型注解/strict-typing 警告、`packing` deprecation 和设备系统能力警告。consumer 使用本地 HAR 依赖产生 packing 警告，符合本地验证用途，不作为可发布 consumer。KMP consumer 有 bundle ID 推断警告。

未验证：真机微信安装/版本分支、真实 OAuth 授权返回、Android 签名/固定 Activity 接线、iOS URL Scheme/Universal Link、OHOS 签名回跳、朋友圈/好友实际分享界面、转账确认页展示和远程发布坐标。设备与服务端结果不能从本地编译和桩检查推断。
