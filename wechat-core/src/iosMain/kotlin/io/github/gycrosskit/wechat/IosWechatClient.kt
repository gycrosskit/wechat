package io.github.gycrosskit.wechat

/** 宿主 Swift 适配器实现此接口；核心库不链接或复制 WechatOpenSDK。 */
interface IosWechatBridge : WechatClient
class IosWechatClient(private val bridge: IosWechatBridge) : WechatClient by bridge
