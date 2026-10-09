import io.github.gycrosskit.wechat.*
import io.github.gycrosskit.wechat.kuikly.registerWechatModule
fun registerReceiver(renderer: com.tencent.kuikly.core.render.android.IKuiklyRenderExport, client: AndroidWechatClient) {
    renderer.registerWechatModule(client)
}
