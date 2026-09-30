import android.content.Context
import android.content.Intent
import io.github.gycrosskit.wechat.*
fun androidProbe(context: Context, listener: WechatListener): (Intent) -> Boolean {
    val client = AndroidWechatClient(context, "host-app-id", listener)
    return client::handleIntent
}
