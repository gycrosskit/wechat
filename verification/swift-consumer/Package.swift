// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WechatConsumer", platforms: [.iOS(.v15)],
    products: [.library(name: "WechatConsumer", targets: ["WechatConsumer"])],
    dependencies: [.package(url: "https://github.com/gycrosskit/wechat.git", revision: "native-0.1.8")],
    targets: [.target(name: "WechatConsumer", dependencies: [.product(name: "GycWechatNative", package: "wechat")])])
