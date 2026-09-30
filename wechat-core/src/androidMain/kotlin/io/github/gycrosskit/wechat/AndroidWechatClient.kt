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
class AndroidWechatClient(context: Context, appId: String, private val listener: WechatListener) : WechatClient {
    private val main = Handler(Looper.getMainLooper())
    private val images = Executors.newSingleThreadExecutor()
    private val session = WechatSession()
    private val api = WXAPIFactory.createWXAPI(context.applicationContext, appId, true)
    private val handler = object : IWXAPIEventHandler {
        override fun onReq(req: BaseReq) = Unit
        override fun onResp(resp: BaseResp) = handleResponse(resp)
    }
    private val registered: Boolean
    init { require(appId.isNotBlank()); registered = api.registerApp(appId) }

    fun handleIntent(intent: Intent): Boolean {
        checkMain()
        return runCatching { api.handleIntent(intent, handler) }.getOrDefault(false)
    }
    override fun authorize(requestId: String) {
        val state = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
        if (!begin(requestId, WechatKind.AUTHORIZATION, state)) return
        send(requestId, SendAuth.Req().apply { scope = "snsapi_userinfo"; this.state = state })
    }
    override fun shareImage(requestId: String, data: ByteArray, scene: WechatScene) {
        if (!begin(requestId, WechatKind.SHARE)) return
        if (data.isEmpty() || data.size > MAX_IMAGE) { fail(requestId, WechatStatus.INVALID_CONTENT); return }
        val copy = data.copyOf()
        images.execute {
            val thumb = runCatching { thumbnail(copy) }.getOrNull()
            main.post {
                if (!session.isCurrent(requestId)) return@post
                if (thumb == null) { fail(requestId, WechatStatus.INVALID_CONTENT); return@post }
                sendShare(requestId, WXMediaMessage(WXImageObject(copy)).apply { thumbData = thumb }, scene)
            }
        }
    }
    override fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene) {
        if (!begin(requestId, WechatKind.SHARE)) return
        val uri = runCatching { Uri.parse(url) }.getOrNull()
        if (uri == null || uri.scheme?.lowercase() !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.userInfo != null || url.toByteArray().size > 10 * 1024 || thumbnail.isEmpty() || thumbnail.size > MAX_IMAGE) {
            fail(requestId, WechatStatus.INVALID_CONTENT); return
        }
        val copy = thumbnail.copyOf()
        images.execute {
            val thumb = runCatching { thumbnail(copy) }.getOrNull()
            main.post {
                if (!session.isCurrent(requestId)) return@post
                if (thumb == null) { fail(requestId, WechatStatus.INVALID_CONTENT); return@post }
                sendShare(requestId, WXMediaMessage(WXWebpageObject().apply { webpageUrl = url }).apply {
                    this.title = title; this.description = description; thumbData = thumb
                }, scene)
            }
        }
    }
    override fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String) {
        if (!begin(requestId, WechatKind.MERCHANT_TRANSFER)) return
        if (merchantId.isBlank() || appId.isBlank() || packageValue.isBlank()) { fail(requestId, WechatStatus.INVALID_CONTENT); return }
        if (api.wxAppSupportAPI < 0x28002d33) { fail(requestId, WechatStatus.UNSUPPORTED); return }
        send(requestId, WXOpenBusinessView.Req().apply {
            businessType = "requestMerchantTransfer"
            query = "mchId=${Uri.encode(merchantId)}&appId=${Uri.encode(appId)}&package=${Uri.encode(packageValue)}"
        })
    }
    override fun cancel(requestId: String) {
        checkMain()
        if (session.cancel(requestId)) listener.onSubmitted(requestId, WechatStatus.CANCELLED)
    }
    private fun handleResponse(resp: BaseResp) {
        checkMain()
        val kind = when (resp) {
            is SendAuth.Resp -> WechatKind.AUTHORIZATION
            is SendMessageToWX.Resp -> WechatKind.SHARE
            is WXOpenBusinessView.Resp -> if (resp.businessType == "requestMerchantTransfer") WechatKind.MERCHANT_TRANSFER else return
            else -> return
        }
        val pending = session.consume(resp.transaction, kind, (resp as? SendAuth.Resp)?.state) ?: return
        val code = (resp as? SendAuth.Resp)?.code?.takeIf { resp.errCode == 0 && it.isNotBlank() }
        val page = (resp as? WXOpenBusinessView.Resp)?.extMsg?.let { runCatching { JSONObject(it).optString("result").takeIf(String::isNotBlank) }.getOrNull() }
        listener.onReceipt(WechatReceipt(pending.id, kind, if (kind == WechatKind.AUTHORIZATION && resp.errCode == 0 && code == null) -1 else resp.errCode, code, page))
    }
    private var transaction: String = ""
    private fun begin(id: String, kind: WechatKind, state: String? = null): Boolean {
        checkMain()
        val token = UUID.randomUUID().toString()
        val rejected = session.begin(id, token, kind, state)
        if (rejected != null) { listener.onSubmitted(id, rejected); return false }
        transaction = token
        if (!registered) { fail(id, WechatStatus.FAILED); return false }
        if (!api.isWXAppInstalled) { fail(id, WechatStatus.NOT_INSTALLED); return false }
        return true
    }
    private fun sendShare(id: String, message: WXMediaMessage, scene: WechatScene) {
        if (scene == WechatScene.TIMELINE && api.wxAppSupportAPI < Build.TIMELINE_SUPPORTED_SDK_INT) { fail(id, WechatStatus.UNSUPPORTED); return }
        send(id, SendMessageToWX.Req().apply { this.message = message; this.scene = if (scene == WechatScene.TIMELINE) SendMessageToWX.Req.WXSceneTimeline else SendMessageToWX.Req.WXSceneSession })
    }
    private fun send(id: String, request: BaseReq) {
        request.transaction = transaction
        val accepted = runCatching { request.checkArgs() && api.sendReq(request) }.getOrDefault(false)
        if (!accepted) session.cancel(id)
        listener.onSubmitted(id, if (accepted) WechatStatus.REQUESTED else WechatStatus.FAILED)
    }
    private fun fail(id: String, status: WechatStatus) { session.cancel(id); listener.onSubmitted(id, status) }
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
    private companion object { const val MAX_IMAGE = 10 * 1024 * 1024 }
}
