package io.github.gycrosskit.wechat.kuikly

import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.tencent.kuikly.core.render.android.IKuiklyRenderExport
import com.tencent.kuikly.core.render.android.export.KuiklyRenderBaseModule
import com.tencent.kuikly.core.render.android.export.KuiklyRenderCallback
import io.github.gycrosskit.wechat.*
import org.json.JSONObject

/** 每 Renderer 创建，注入 Application 持有的同一个 client；不替换宿主监听或 WXEntryActivity 接线。 */
class AndroidWechatModule(private val client: AndroidWechatClient) : KuiklyRenderBaseModule(), WechatListener {
    private val main = Handler(Looper.getMainLooper())
    private val ids = mutableSetOf<String>()
    private val submissions = mutableMapOf<String, KuiklyRenderCallback>()
    private val receivedBeforeSubmission = mutableSetOf<String>()
    private val cancelling = mutableSetOf<String>()
    private var listener: KuiklyRenderCallback? = null
    @Volatile private var destroyed = false
    private var released = false

    override fun call(method: String, params: String?, callback: KuiklyRenderCallback?): Any? {
        onMain {
            if (destroyed || released) return@onMain
            val args = runCatching { JSONObject(params ?: "{}") }.getOrNull()
            if (args == null) { callback?.invoke(status("invalid_content")); return@onMain }
            if (method == "listen") {
                listener = callback
                val restored = args.opt("restoredRequestId") as? String
                if (restored != null && client.canResume(restored)) ids.add(restored)
                client.addModuleListener(this, ids)
                return@onMain
            }
            if (method == "unlisten") { release(); return@onMain }
            if (listener == null) { callback?.invoke(status("unsupported")); return@onMain }
            val id = args.opt("requestId") as? String
            if (id.isNullOrBlank() || id.length > 128) { callback?.invoke(status("invalid_content")); return@onMain }
            if (method == "cancel") {
                if (id !in ids) { callback?.invoke(status("no_pending")); return@onMain }
                cancelling.add(id)
                client.cancel(id) { result ->
                    cancelling.remove(id)
                    if (result.getOrNull() == true) { ids.remove(id); submissions.remove(id); receivedBeforeSubmission.remove(id) }
                    if (!destroyed && !released) callback?.invoke(status(when {
                        result.isFailure -> "failed"
                        result.getOrNull() == true -> "cancelled"
                        else -> "no_pending"
                    }))
                }
                return@onMain
            }
            if (client.hasModuleOwner(id)) { callback?.invoke(status("busy")); return@onMain }
            if (method !in listOf("authorize", "image", "webpage", "transfer")) { callback?.invoke(status("unsupported")); return@onMain }
            ids.add(id)
            callback?.let { submissions[id] = it }
            try {
                when (method) {
                    "authorize" -> client.authorize(id)
                    "image" -> client.shareImage(id, bytes(args, "data"), scene(args), optional(args, "recipientId"), optional(args, "senderOpenId"))
                    "webpage" -> client.shareWebPage(id, text(args, "url"), text(args, "title"), text(args, "description"), bytes(args, "thumbnail"), scene(args))
                    else -> client.openMerchantTransfer(id, text(args, "merchantId"), text(args, "appId"), text(args, "packageValue"))
                }
            } catch (_: IllegalArgumentException) { onSubmitted(id, WechatStatus.INVALID_CONTENT) }
              catch (_: Exception) {
                if (client.hasPendingRequest(id)) submissions.remove(id)?.invoke(status("pending"))
                else onSubmitted(id, WechatStatus.FAILED)
            }
        }
        return null
    }

    override fun onSubmitted(requestId: String, status: WechatStatus) {
        if (destroyed || released || requestId !in ids) return
        if (status == WechatStatus.CANCELLED && requestId in cancelling) return
        val callback = submissions.remove(requestId)
        if (status != WechatStatus.REQUESTED || receivedBeforeSubmission.remove(requestId)) ids.remove(requestId)
        callback?.invoke(status(status.name.lowercase()))
    }
    override fun onReceipt(receipt: WechatReceipt) {
        val id = receipt.requestId ?: return
        if (destroyed || released || id !in ids) return
        if (submissions.containsKey(id)) receivedBeforeSubmission.add(id) else ids.remove(id)
        listener?.invoke(JSONObject().apply {
            put("requestId", id)
            put("kind", when (receipt.kind) { WechatKind.AUTHORIZATION -> "authorization"; WechatKind.SHARE -> "share"; else -> "merchant_transfer" })
            put("errorCode", receipt.errorCode); put("attribution", receipt.attribution.name)
            receipt.authorizationCode?.let { put("authorizationCode", it) }; receipt.pageResult?.let { put("pageResult", it) }
            receipt.candidateRequestId?.let { put("candidateRequestId", it) }
        }.toString())
    }
    override fun onDestroy() {
        destroyed = true
        onMain { release() }
        super.onDestroy()
    }
    private fun release() {
        if (released) return
        released = true
        client.removeModuleListener(this)
        val pending = ids.toList(); ids.clear(); submissions.clear(); receivedBeforeSubmission.clear(); cancelling.clear(); listener = null
        pending.forEach(client::cancel)
    }
    private fun onMain(action: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post { action() } }
    private fun status(value: String): String = JSONObject().put("status", value).toString()
    private fun text(args: JSONObject, key: String): String = args.opt(key) as? String ?: throw IllegalArgumentException()
    private fun optional(args: JSONObject, key: String): String? = if (args.has(key)) text(args, key) else null
    private fun scene(args: JSONObject): WechatScene = when (text(args, "scene")) {
        "session" -> WechatScene.SESSION; "timeline" -> WechatScene.TIMELINE; else -> throw IllegalArgumentException()
    }
    private fun bytes(args: JSONObject, key: String): ByteArray {
        val value = text(args, key)
        require(value.length in 1..34_952_536)
        return Base64.decode(value, Base64.NO_WRAP).also { require(it.size in 1..25 * 1024 * 1024) }
    }
    companion object { const val NAME = "GycWechat" }
}

/** 每 Renderer 新建 receiver，client 复用 Application 持有且处理 WXEntryActivity 回跳的同一实例。 */
fun IKuiklyRenderExport.registerWechatModule(client: AndroidWechatClient) {
    moduleExport(AndroidWechatModule.NAME) { AndroidWechatModule(client) }
}
