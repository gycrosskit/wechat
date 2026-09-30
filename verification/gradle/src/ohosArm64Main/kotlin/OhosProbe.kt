import io.github.gycrosskit.wechat.*
import io.github.gycrosskit.wechat.kuikly.WechatModule
fun ohosProbe(listener: WechatListener): WechatClient = WechatModule().apply { attach(listener, "restored-id") }
