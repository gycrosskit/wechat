import GycWechatNative

// Compile as an independent consumer of the built optional Pod, without compiling receiver sources.
func configureNativeReceiver(_ native: WechatClient) {
    WechatModule.clientProvider = { native }
    WechatModule.register()
    let receiver = WechatModule()
    _ = receiver.hrv_call(withMethod: "listen", params: "{}", callback: { _ in })
    receiver.invalidate()
}
