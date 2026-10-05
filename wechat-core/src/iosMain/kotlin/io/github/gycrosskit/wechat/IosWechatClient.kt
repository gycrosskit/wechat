package io.github.gycrosskit.wechat

/** 宿主 Swift 适配器实现此接口；核心库不链接或复制 WechatOpenSDK。 */
interface IosWechatBridge : WechatClient
/** 直接复用宿主 Swift Bridge 的主线程与所有权契约，不增加第二份请求状态。 */
class IosWechatClient(private val bridge: IosWechatBridge) : WechatClient by bridge
