package io.github.gycrosskit.wechat

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.tencent.mm.opensdk.constants.Build
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelbiz.WXOpenBusinessView
import com.tencent.mm.opensdk.modelmsg.*
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

/** 宿主 Application 持有唯一实例，固定 wxapi Activity 把 Intent 交给 handleIntent。 */
class AndroidWechatClient(context: Context, appId: String, listener: WechatListener? = null, store: WechatRequestStore? = null) : WechatClient {
    private val main = Handler(Looper.getMainLooper())
    private val images = Executors.newSingleThreadExecutor()
    private val session by lazy { checkMain(); WechatSession(store) }
    private class Owner(val listener: WechatListener)
    private class Request(val id: String, val owner: Owner?) {
        val transaction = UUID.randomUUID().toString()
        var cancelled = false
    }
    @Volatile private var desiredOwner = listener?.let(::Owner)
    private var activeOwner = desiredOwner
    private val queued = mutableMapOf<String, Request>()
    private val cancelledBeforeBegin = mutableSetOf<String>()
    private var currentRequest: Request? = null
    private val receipts = mutableListOf<Pair<WechatListener?, WechatReceipt>>()
    private val application = context.applicationContext
    private val api by lazy { checkMain(); WXAPIFactory.createWXAPI(application, appId, true) }
    private val handler = object : IWXAPIEventHandler {
        override fun onReq(req: BaseReq) = Unit
        override fun onResp(resp: BaseResp) = onMain { handleResponse(resp) }
    }
    private val registered by lazy { checkMain(); api.registerApp(appId) }
    init { require(appId.isNotBlank()) }

    fun attach(listener: WechatListener) {
        val owner = Owner(listener)
        desiredOwner = owner
        onMain {
            if (desiredOwner !== owner) return@onMain
            activeOwner = owner
            val buffered = receipts.filter { it.first == null || it.first === listener }
            for (entry in buffered) {
                if (desiredOwner !== owner) break
                receipts.remove(entry)
                listener.onReceipt(entry.second)
            }
        }
    }
    fun detach() {
        desiredOwner = null
        onMain { if (desiredOwner == null) activeOwner = null }
    }
    /** 同步兼容入口仅限 Main；沿用 false 表示未处理（含 SDK 异常）。精确异常用 Result 重载。 */
    fun handleIntent(intent: Intent): Boolean {
        checkMain()
        return runCatching { handleIntentOnMain(intent) }.getOrDefault(false)
    }
    /** callback 在主线程返回 SDK 实际 Boolean 或初始化/处理异常，不阻塞且不以 false 冒充异常。 */
    fun handleIntent(intent: Intent, callback: (Result<Boolean>) -> Unit) {
        val copy = Intent(intent)
        onMain { callback(runCatching { handleIntentOnMain(copy) }) }
    }
    private fun handleIntentOnMain(intent: Intent): Boolean {
        checkMain()
        registered // 冷启动回跳也先尝试注册；注册结果不替代 SDK handleIntent 的真实结果。
        return api.handleIntent(intent, handler)
    }
    override fun authorize(requestId: String) = submit(requestId) { request ->
        val state = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
        if (begin(request, WechatKind.AUTHORIZATION, state)) {
            send(request, SendAuth.Req().apply { scope = "snsapi_userinfo"; this.state = state })
        }
    }
    override fun shareImage(requestId: String, data: ByteArray, scene: WechatScene, recipientId: String?, senderOpenId: String?) {
        // 入队前取得快照，调用方随后修改数组不能改变已提交内容。
        val copy = if (data.size in 1..MAX_WECHAT_IMAGE) data.copyOf() else byteArrayOf()
        submit(requestId) { request ->
            if (!begin(request, WechatKind.SHARE)) return@submit
            if (recipientId != null && (recipientId.isBlank() || scene != WechatScene.SESSION)) { fail(request, WechatStatus.INVALID_CONTENT); return@submit }
            if (recipientId != null && (api.wxAppSupportAPI < Build.SEND_TO_SPECIFIED_CONTACT_SDK_INT || senderOpenId.isNullOrBlank())) { fail(request, WechatStatus.UNSUPPORTED); return@submit }
            if (copy.isEmpty() || copy.size > MAX_WECHAT_IMAGE) { fail(request, WechatStatus.INVALID_CONTENT); return@submit }
            if (copy.size > 10 * 1024 * 1024 && api.wxAppSupportAPI < Build.SEND_25M_IMAGE_SDK_INT) { fail(request, WechatStatus.UNSUPPORTED); return@submit }
            images.execute {
                val thumb = runCatching { thumbnail(copy) }.getOrNull()
                onMain {
                    if (currentRequest !== request || !session.isCurrent(request.id)) return@onMain
                    if (thumb == null) { fail(request, WechatStatus.INVALID_CONTENT); return@onMain }
                    sendShare(request, WXMediaMessage(WXImageObject(copy)).apply { thumbData = thumb }, scene, recipientId, senderOpenId)
                }
            }
        }
    }
    override fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene) {
        val copy = if (thumbnail.size in 1..MAX_WECHAT_IMAGE) thumbnail.copyOf() else byteArrayOf()
        submit(requestId) { request ->
            if (!begin(request, WechatKind.SHARE)) return@submit
            val uri = runCatching { Uri.parse(url) }.getOrNull()
            if (uri == null || uri.scheme?.lowercase() !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.userInfo != null || url.toByteArray().size > 10 * 1024 || copy.isEmpty() || copy.size > MAX_WECHAT_IMAGE) {
                fail(request, WechatStatus.INVALID_CONTENT); return@submit
            }
            images.execute {
                val thumb = runCatching { thumbnail(copy) }.getOrNull()
                onMain {
                    if (currentRequest !== request || !session.isCurrent(request.id)) return@onMain
                    if (thumb == null) { fail(request, WechatStatus.INVALID_CONTENT); return@onMain }
                    sendShare(request, WXMediaMessage(WXWebpageObject().apply { webpageUrl = url }).apply {
                        this.title = wechatText(title, 256, 512); this.description = wechatText(description, 512, 1024); thumbData = thumb
                    }, scene)
                }
            }
        }
    }
    override fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String) = submit(requestId) { request ->
        if (!begin(request, WechatKind.MERCHANT_TRANSFER)) return@submit
        if (merchantId.isBlank() || appId.isBlank() || packageValue.isBlank()) { fail(request, WechatStatus.INVALID_CONTENT); return@submit }
        if (api.wxAppSupportAPI < 0x28002d33) { fail(request, WechatStatus.UNSUPPORTED); return@submit }
        send(request, WXOpenBusinessView.Req().apply {
            businessType = "requestMerchantTransfer"
            query = "mchId=${Uri.encode(merchantId)}&appId=${Uri.encode(appId)}&package=${Uri.encode(packageValue)}"
        })
    }
    override fun cancel(requestId: String) = onMain {
        val waiting = synchronized(queued) { queued[requestId] }
        val request = currentRequest
        val cancelQueued = waiting != null && !waiting.cancelled
        if (waiting != null && cancelQueued) {
            waiting.cancelled = true
            cancelledBeforeBegin.add(requestId)
        }
        // 恢复后优先清除可信 pending，避免同 ID 的排队重复请求遮蔽冷启动记录。
        // 清除失败不是原提交终态；保留 pending/owner，让迟回执或取消重试继续匹配。
        val cancelled = try { session.cancel(requestId) } catch (_: Exception) { return@onMain }
        if (cancelled) {
            receipts.removeAll { it.second.requestId == requestId }
            currentRequest = null
            submitted(request ?: Request(requestId, desiredOwner), WechatStatus.CANCELLED)
        } else if (waiting != null && cancelQueued) {
            submitted(waiting, WechatStatus.CANCELLED)
        } else receipts.removeAll { it.second.requestId == requestId }
    }
    private fun submit(id: String, action: (Request) -> Unit) {
        val request = Request(id, desiredOwner)
        if (id.isBlank() || id.length > 128) {
            onMain { submitted(request, WechatStatus.INVALID_CONTENT) }
            return
        }
        val inserted = synchronized(queued) { if (id in queued) false else { queued[id] = request; true } }
        onMain {
            if (!inserted) { submitted(request, WechatStatus.INVALID_CONTENT); return@onMain }
            synchronized(queued) { queued.remove(id) }
            if (!request.cancelled) action(request)
        }
    }
    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post { action() }
    }
    private fun submitted(request: Request, status: WechatStatus) {
        val owner = activeOwner
        if (owner === desiredOwner && (request.owner == null || request.owner.listener === owner?.listener)) owner?.listener?.onSubmitted(request.id, status)
    }
    private fun handleResponse(resp: BaseResp) {
        checkMain()
        val kind = when (resp) {
            is SendAuth.Resp -> WechatKind.AUTHORIZATION
            is SendMessageToWX.Resp -> WechatKind.SHARE
            is WXOpenBusinessView.Resp -> if (resp.businessType == "requestMerchantTransfer") WechatKind.MERCHANT_TRANSFER else return
            else -> return
        }
        val pending = try { session.consume(resp.transaction, kind, (resp as? SendAuth.Resp)?.state) } catch (_: Exception) { null } ?: return
        val owner = currentRequest?.takeIf { it.id == pending.requestId }?.owner
        currentRequest = null
        val code = (resp as? SendAuth.Resp)?.code?.takeIf { resp.errCode == 0 && it.isNotBlank() }
        val page = (resp as? WXOpenBusinessView.Resp)?.extMsg?.let { runCatching { JSONObject(it).optString("result").takeIf(String::isNotBlank) }.getOrNull() }
        deliver(WechatReceipt(pending.requestId, kind, if (kind == WechatKind.AUTHORIZATION && resp.errCode == 0 && code == null) -1 else resp.errCode, code, page), owner)
    }
    private fun deliver(receipt: WechatReceipt, requestOwner: Owner?) {
        val owner = activeOwner
        if (owner != null && owner === desiredOwner && (requestOwner == null || owner.listener === requestOwner.listener)) owner.listener.onReceipt(receipt)
        else {
            // ponytail: 最多缓存 64 笔归一回执；有原 owner 时仅允许同一 listener 重新 attach 回放。
            if (receipts.size == 64) receipts.removeAt(0)
            receipts.add(requestOwner?.listener to receipt)
        }
    }
    private fun begin(request: Request, kind: WechatKind, state: String? = null): Boolean {
        if (request.id in cancelledBeforeBegin) { submitted(request, WechatStatus.INVALID_CONTENT); return false }
        val rejected = try { session.begin(request.id, request.transaction, kind, state) } catch (_: Exception) { WechatStatus.FAILED }
        if (rejected != null) { submitted(request, rejected); return false }
        currentRequest = request
        val unavailable = runCatching {
            if (!registered) WechatStatus.FAILED else if (!api.isWXAppInstalled) WechatStatus.NOT_INSTALLED else null
        }.getOrElse { WechatStatus.FAILED }
        if (unavailable != null) { fail(request, unavailable); return false }
        return true
    }
    private fun sendShare(request: Request, message: WXMediaMessage, scene: WechatScene, recipientId: String? = null, senderOpenId: String? = null) {
        if (scene == WechatScene.TIMELINE && api.wxAppSupportAPI < Build.TIMELINE_SUPPORTED_SDK_INT) { fail(request, WechatStatus.UNSUPPORTED); return }
        send(request, SendMessageToWX.Req().apply {
            this.message = message
            this.scene = when {
                recipientId != null -> SendMessageToWX.Req.WXSceneSpecifiedContact
                scene == WechatScene.TIMELINE -> SendMessageToWX.Req.WXSceneTimeline
                else -> SendMessageToWX.Req.WXSceneSession
            }
            userOpenId = recipientId
            if (recipientId != null) openId = senderOpenId
        })
    }
    private fun send(request: Request, sdkRequest: BaseReq) {
        sdkRequest.transaction = request.transaction
        val accepted = runCatching { sdkRequest.checkArgs() && api.sendReq(sdkRequest) }.getOrDefault(false)
        if (accepted) submitted(request, WechatStatus.REQUESTED) else fail(request, WechatStatus.FAILED)
    }
    private fun fail(request: Request, status: WechatStatus) {
        val cleared = runCatching { session.cancel(request.id) }.getOrDefault(false)
        if (cleared) currentRequest = null
        submitted(request, if (cleared) status else WechatStatus.FAILED)
    }
    private fun checkMain() { check(Looper.myLooper() == Looper.getMainLooper()) { "WeChat must run on main thread" } }
    private fun thumbnail(data: ByteArray): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 320) sample *= 2
        val image = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        try {
            val output = ByteArrayOutputStream()
            for (quality in 90 downTo 10 step 10) {
                output.reset(); image.compress(Bitmap.CompressFormat.JPEG, quality, output)
                if (output.size() <= 32 * 1024) return output.toByteArray()
            }
            return null
        } finally { image.recycle() }
    }
}
