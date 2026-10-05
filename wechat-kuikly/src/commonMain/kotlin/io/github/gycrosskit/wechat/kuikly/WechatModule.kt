package io.github.gycrosskit.wechat.kuikly

import com.tencent.kuikly.core.module.CallbackRef
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.wechat.*
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
/** 页面线程使用；attach 后提交请求，dispose 撤销所有回调并通知原生取消本页等待。 */
class WechatModule : Module(), WechatClient {
    private var listener: WechatListener? = null
    private var listening: CallbackRef? = null
    private val callbacks = mutableMapOf<String, CallbackRef>()
    private val cancellations = mutableMapOf<String, CallbackRef>()
    private var disposed = false
    override fun moduleName(): String = NAME
    /** 注册长期回执；restoredRequestId 只能取宿主可信业务记录，不从页面回跳恢复。 */
    fun attach(listener: WechatListener, restoredRequestId: String? = null) {
        if (disposed) return
        this.listener = listener
        if (listening != null) return
        listening = toNative(true, "listen", JSONObject().apply { restoredRequestId?.let { put("restoredRequestId", it) } }.toString(), { payload ->
            if (disposed || payload == null) return@toNative
            val kind = when (payload.optString("kind")) {
                "authorization" -> WechatKind.AUTHORIZATION
                "share" -> WechatKind.SHARE
                "merchant_transfer" -> WechatKind.MERCHANT_TRANSFER
                else -> return@toNative
            }
            this.listener?.onReceipt(WechatReceipt(payload.optString("requestId"), kind, payload.optInt("errorCode"), payload.optString("authorizationCode").takeIf(String::isNotBlank), payload.optString("pageResult").takeIf(String::isNotBlank)))
        }, false).callbackRef
    }
    override fun authorize(requestId: String) = call(requestId, "authorize", JSONObject())
    override fun shareImage(requestId: String, data: ByteArray, scene: WechatScene, recipientId: String?, senderOpenId: String?) {
        if (data.isEmpty() || data.size > MAX_IMAGE) { listener?.onSubmitted(requestId, WechatStatus.INVALID_CONTENT); return }
        call(requestId, "image", JSONObject().apply { put("data", Base64.encode(data)); put("scene", sceneValue(scene)); recipientId?.let { put("recipientId", it) }; senderOpenId?.let { put("senderOpenId", it) } })
    }
    override fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene) {
        if (thumbnail.isEmpty() || thumbnail.size > MAX_IMAGE) { listener?.onSubmitted(requestId, WechatStatus.INVALID_CONTENT); return }
        call(requestId, "webpage", JSONObject().apply { put("url", url); put("title", title); put("description", description); put("thumbnail", Base64.encode(thumbnail)); put("scene", sceneValue(scene)) })
    }
    override fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String) =
        call(requestId, "transfer", JSONObject().apply { put("merchantId", merchantId); put("appId", appId); put("packageValue", packageValue) })
    override fun cancel(requestId: String) {
        if (disposed || listening == null || cancellations.containsKey(requestId)) return
        var completed = false
        val ref = toNative(false, "cancel", JSONObject().apply { put("requestId", requestId) }.toString(), { payload ->
            completed = true
            cancellations.remove(requestId)
            // 取消失败不是原请求提交失败；原 pending 和迟回执仍由同一 owner 接收。
            if (!disposed && payload?.optString("status") == "cancelled") {
                callbacks.remove(requestId)?.let(::removeCallback)
                listener?.onSubmitted(requestId, WechatStatus.CANCELLED)
            }
        }, false).callbackRef
        if (!completed && ref != null) cancellations[requestId] = ref
    }
    private fun call(id: String, method: String, args: JSONObject) {
        if (disposed) { listener?.onSubmitted(id, WechatStatus.CANCELLED); return }
        if (listening == null) { listener?.onSubmitted(id, WechatStatus.UNSUPPORTED); return }
        if (callbacks.containsKey(id)) { listener?.onSubmitted(id, WechatStatus.BUSY); return }
        args.put("requestId", id)
        var completed = false
        val ref = toNative(false, method, args.toString(), { payload ->
            completed = true; callbacks.remove(id)
            val status = when (payload?.optString("status")) {
                "requested" -> WechatStatus.REQUESTED
                "busy" -> WechatStatus.BUSY
                "not_installed" -> WechatStatus.NOT_INSTALLED
                "unsupported" -> WechatStatus.UNSUPPORTED
                "invalid_content" -> WechatStatus.INVALID_CONTENT
                "cancelled" -> WechatStatus.CANCELLED
                "pending" -> null
                else -> WechatStatus.FAILED
            }
            if (!disposed && status != null) listener?.onSubmitted(id, status)
        }, false).callbackRef
        if (!completed && ref != null) callbacks[id] = ref
    }
    /** 幂等撤销长期监听、提交/取消确认回调和页面 owner；迟到消息不交付。 */
    fun dispose() {
        if (disposed) return
        disposed = true
        toNative(false, "unlisten", "{}", null, false)
        listening?.let(::removeCallback); listening = null
        callbacks.values.forEach(::removeCallback); callbacks.clear(); listener = null
        cancellations.values.forEach(::removeCallback); cancellations.clear()
    }
    private fun sceneValue(scene: WechatScene): String = if (scene == WechatScene.TIMELINE) "timeline" else "session"
    companion object {
        /** 原生模块注册名。 */
        const val NAME = "GycWechat"
        private const val MAX_IMAGE = 25 * 1024 * 1024
    }
}
