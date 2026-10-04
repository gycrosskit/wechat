import io.github.gycrosskit.wechat.*
import io.github.gycrosskit.wechat.kuikly.WechatModule
fun ohosProbe(listener: WechatListener): WechatClient = WechatModule().apply { attach(listener, "restored-id") }

fun cancelProbe(module: WechatModule) { module.cancel("compile-only-id"); module.dispose() }
