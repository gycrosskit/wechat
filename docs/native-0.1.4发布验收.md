# native-0.1.4 原生发布验收

2026-10-05。仅修复 Swift OAuth 成功回执中 nil、空或纯 Unicode 空白 code，合法 code 原文保留。Maven `0.1.5` 与 HAR `0.1.4` 沿用已有产物；此标签不生成新的 Maven 坐标。

## 不可变版本与真实文件

- [源码 PR #16](https://github.com/gycrosskit/wechat/pull/16) 已经保护分支合并。
- Git Pod source tag / SPM revision `native-0.1.4` 固定提交 `317a252a5e7779ae17f637d7d59f807de83112a2`；podspec 内部版本 `0.1.4`。
- [Release](https://github.com/gycrosskit/wechat/releases/tag/native-0.1.4) 的 `wechat-native-source.tar.gz` 已实际重新下载，SHA-256：`52180d42a711f1d840c4921c6138570063133f297f2f11d8c22dfc1b40827e3f`。
- 没有覆盖旧标签；没有将空检查列表写成 CI 通过。

## 实际消费与回归

新建 Git Pod 消费工程使用远程 `:git`/`:tag`，不是本地 `:path`；锁文件 commit、安装源码和实际参与编译的全部2个Swift文件与标签逐字节一致。WechatOpenSDK-XCFramework `2.0.7`，真实 iphoneos SDK、arm64/iOS15 UIKit App及debug.dylib完整链接通过。

新建 Swift Package 消费工程固定 `.revision("native-0.1.4")`，Package.resolved 指向相同提交；接线真实微信 XCFramework device slice，实际 arm64/iOS15 包及 Probe 编译通过。SPM 本身不包含厂商 binaryTarget，宿主仍须提供该依赖。

`python3 tests/swift-receipt.py` 提取完整生产 onResp 与实际 Session 执行，覆盖 nil/空/ASCII/Unicode 空白、带空白合法 code、verified/requestId 和一次消费。此回归隔离外部微信调用，不代替厂商编译证据。

新建远程 Maven Core `0.1.5` 消费者实际导出 arm64 `WechatCore.framework`，精确 GAV/纯远程守卫通过；`iosApp/KmpWechatBridge.swift` 与真实远程 `native-0.1.4` 的 GycWechatNative Framework、iphoneos SDK 在 arm64/iOS15 下 typecheck 通过。此项是组合桥签名验证；整个组合宿主 App 未在此轮重建，独立 Native UIKit App 最终链接已单独验证。证据保留于 `build/full-review/remote-native-proof.json` 与相应消费日志。

真实微信授权/分享/转账回跳、AppID/Universal Link、指定联系人和宿主业务接线未做设备验收；由使用方验证。资金到账以服务端为准，singlePending 不代表准确的 SDK transaction 归属。
