// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WechatConsumer", platforms: [.iOS(.v15)],
    products: [.library(name: "WechatConsumer", targets: ["WechatConsumer"])],
    dependencies: [.package(path: "../..")],
    targets: [.target(name: "WechatConsumer", dependencies: [.product(name: "GycWechatNative", package: "wechat")])])
