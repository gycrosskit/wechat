// swift-tools-version: 5.9
import PackageDescription
// WechatOpenSDK 由宿主通过 CocoaPods 或官方 XCFramework 提供，本包只依赖它的公开模块。
let package = Package(name: "GycWechatNative", platforms: [.iOS(.v15)],
    products: [.library(name: "GycWechatNative", targets: ["GycWechatNative"])],
    targets: [.target(name: "GycWechatNative", path: "iosApp/Sources/GycWechatNative",
        linkerSettings: [.linkedFramework("WechatOpenSDK"), .linkedFramework("Security"), .linkedFramework("CoreTelephony"), .linkedLibrary("z"), .linkedLibrary("c++")])])
