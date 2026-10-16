// swift-tools-version: 5.9
import PackageDescription
import Foundation

guard let nativeTag = ProcessInfo.processInfo.environment["VERSION"],
      nativeTag.range(of: #"^native-[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
    fatalError("VERSION must be an immutable native release tag, such as native-1.2.3")
}

let package = Package(name: "WechatConsumer", platforms: [.iOS(.v15)],
    products: [.library(name: "WechatConsumer", targets: ["WechatConsumer"])],
    dependencies: [.package(url: "https://github.com/gycrosskit/wechat.git", revision: nativeTag)],
    targets: [.target(name: "WechatConsumer", dependencies: [.product(name: "GycWechatNative", package: "wechat")])])
