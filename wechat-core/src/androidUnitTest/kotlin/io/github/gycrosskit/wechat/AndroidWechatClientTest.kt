package io.github.gycrosskit.wechat

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Looper
import org.json.JSONObject
import io.github.gycrosskit.wechat.kuikly.AndroidWechatModule
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelbiz.WXOpenBusinessView
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.modelmsg.SendMessageToWX
import com.tencent.mm.opensdk.modelmsg.WXImageObject
import com.tencent.mm.opensdk.openapi.IWXAPI
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import com.tencent.mm.opensdk.constants.Build
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], shadows = [WechatFactoryShadow::class], instrumentedPackages = ["com.tencent.mm.opensdk"])
@LooperMode(LooperMode.Mode.PAUSED)
class AndroidWechatClientTest {
    private val listener = RecordingListener()
    private val store = MainStore()
    private lateinit var client: AndroidWechatClient

    @Before fun setup() {
        WechatFactoryShadow.reset()
        client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", listener, store)
    }

    @Test fun backgroundConstructionAndAuthorizationUseMainAndRealAcceptance() {
        background { client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", listener, store); client.authorize("auth") }
        assertEquals(0, WechatFactoryShadow.created)
        assertEquals(0, store.loads)
        assertTrue(listener.submitted.isEmpty())
        idle()
        assertEquals(1, WechatFactoryShadow.created)
        assertEquals(1, store.loads)
        assertEquals(listOf("auth" to WechatStatus.REQUESTED), listener.submitted)
        assertTrue(WechatFactoryShadow.sent.single() is SendAuth.Req)
        assertTrue(listener.receipts.isEmpty())
        val response = authResponse()
        background { WechatFactoryShadow.respond(response) }
        assertTrue(listener.receipts.isEmpty())
        idle()
        assertEquals("auth", listener.receipts.single().requestId)
        assertEquals("server-code", listener.receipts.single().authorizationCode)
        assertNull(store.saved)
    }

    @Test fun sdkRejectionAndStoreFailureDoNotInventRequested() {
        WechatFactoryShadow.accepted = false
        client.authorize("rejected")
        assertEquals(listOf("rejected" to WechatStatus.FAILED), listener.submitted)
        assertNull(store.saved)
        WechatFactoryShadow.accepted = true
        store.failSave = true
        client.authorize("storage")
        assertEquals("storage" to WechatStatus.FAILED, listener.submitted.last())
        assertEquals(1, WechatFactoryShadow.sent.size)
    }

    @Test fun cancelledQueuedSharingAndTransferNeverReachSdk() {
        background {
            client.shareImage("image", image(), WechatScene.SESSION)
            client.shareWebPage("web", "https://example.com", "title", "description", image(), WechatScene.SESSION)
            client.openMerchantTransfer("transfer", "merchant", "app-id", "package")
        }
        client.cancel("image"); client.cancel("web"); client.cancel("transfer")
        idle()
        assertEquals(listOf("image", "web", "transfer"), listener.submitted.map { it.first })
        assertTrue(listener.submitted.all { it.second == WechatStatus.CANCELLED })
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun mainCompatibilityAndHandleIntentReturnActualSdkBoolean() {
        client.authorize("main")
        assertEquals(WechatStatus.REQUESTED, listener.submitted.single().second)
        WechatFactoryShadow.handled = false
        assertFalse(client.handleIntent(Intent()))
        WechatFactoryShadow.handled = true
        assertTrue(client.handleIntent(Intent()))
        var result: Boolean? = null
        background { client.handleIntent(Intent()) { assertMain(); result = it.getOrThrow() } }
        assertNull(result)
        idle()
        assertEquals(true, result)
        WechatFactoryShadow.handleFailure = true
        assertFalse(client.handleIntent(Intent()))
        var failure: Throwable? = null
        background { client.handleIntent(Intent()) { assertMain(); failure = it.exceptionOrNull() } }
        idle()
        assertTrue(failure is IllegalStateException)
        background { assertFailsWith<IllegalStateException> { client.handleIntent(Intent()) } }
    }

    @Test fun backgroundTransferAndCancelAreSerialized() {
        background { client.openMerchantTransfer("transfer", "merchant", "app-id", "package") }
        idle()
        assertTrue(WechatFactoryShadow.sent.single() is WXOpenBusinessView.Req)
        assertEquals(listOf("transfer" to WechatStatus.REQUESTED), listener.submitted)
        background { client.cancel("transfer") }
        assertNotNull(store.saved)
        idle()
        assertNull(store.saved)
        assertEquals("transfer" to WechatStatus.CANCELLED, listener.submitted.last())
        client.cancel("unknown")
        assertEquals(2, listener.submitted.size)
    }

    @Test fun mainCancelOvertakesQueuedAuthorizationWithoutOpeningWechatAndIdCannotBeReused() {
        background { client.authorize("queued") }
        client.cancel("queued")
        assertEquals(listOf("queued" to WechatStatus.CANCELLED), listener.submitted)
        idle()
        assertTrue(WechatFactoryShadow.sent.isEmpty())
        assertEquals(1, store.loads)
        client.authorize("queued")
        assertEquals("queued" to WechatStatus.INVALID_CONTENT, listener.submitted.last())
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun queuedSubmissionAndLateReceiptCannotMoveToNewListenerOwner() {
        background { client.authorize("old") }
        client.detach()
        val next = RecordingListener()
        client.attach(next)
        idle()
        assertTrue(listener.submitted.isEmpty())
        assertTrue(next.submitted.isEmpty())
        WechatFactoryShadow.respond(authResponse())
        assertTrue(next.receipts.isEmpty())
        client.authorize("new")
        assertEquals(listOf("new" to WechatStatus.REQUESTED), next.submitted)
    }

    @Test fun detachedReceiptReturnsOnlyToSameListenerOnLateAttach() {
        client.authorize("owned")
        val response = authResponse()
        background { client.detach() }
        idle()
        WechatFactoryShadow.respond(response)
        val next = RecordingListener()
        client.attach(next)
        assertTrue(next.receipts.isEmpty())
        background { client.attach(listener) }
        idle()
        assertEquals("owned", listener.receipts.single().requestId)
        client.detach()
        client.attach(listener)
        assertEquals(1, listener.receipts.size)
    }

    @Test fun backgroundAttachDetachCannotOverrideLaterMainAttach() {
        val stale = RecordingListener()
        background { client.detach(); client.attach(stale) }
        val latest = RecordingListener()
        client.attach(latest)
        idle()
        client.authorize("owner")
        assertTrue(stale.submitted.isEmpty())
        assertEquals("owner" to WechatStatus.REQUESTED, latest.submitted.single())
    }

    @Test fun unownedReceiptIsBufferedForLateListenerAndRestorationLoadsOnMain() {
        background { client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", store = store); client.authorize("late") }
        idle()
        WechatFactoryShadow.respond(authResponse())
        assertNull(store.saved)
        background { client.attach(listener) }
        assertTrue(listener.receipts.isEmpty())
        idle()
        assertEquals("late", listener.receipts.single().requestId)
        client.detach()
        val restored = WechatPendingRequest("restored", "trusted-token", WechatKind.AUTHORIZATION, "trusted-state")
        store.saved = restored
        background { client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", listener, store) }
        assertEquals(1, store.loads)
        WechatFactoryShadow.response = SendAuth.Resp().apply { transaction = restored.transaction; state = restored.state; code = "restored-code" }
        background { client.handleIntent(Intent()) {} }
        idle()
        assertEquals(2, store.loads)
        assertEquals(2, WechatFactoryShadow.registrations)
        client.handleIntent(Intent())
        assertEquals(2, WechatFactoryShadow.registrations)
        assertEquals("restored", listener.receipts.last().requestId)
    }

    @Test fun coldCallbackRegistersOnceAndReportsRealResultEvenIfRegistrationReturnsFalse() {
        WechatFactoryShadow.registrationAccepted = false
        var result: Result<Boolean>? = null
        background { client.handleIntent(Intent()) { result = it } }
        idle()
        assertEquals(true, result?.getOrThrow())
        assertEquals(1, WechatFactoryShadow.registrations)
        client.handleIntent(Intent())
        assertEquals(1, WechatFactoryShadow.registrations)
    }

    @Test fun queuedCancellationSurvivesStoreLoadFailureWithoutFalseTerminal() {
        store.failLoad = true
        background { client.authorize("queued") }
        client.cancel("queued")
        assertTrue(listener.submitted.isEmpty())
        store.failLoad = false
        idle()
        assertTrue(WechatFactoryShadow.sent.isEmpty())
        assertTrue(listener.submitted.isEmpty())
        client.authorize("queued")
        assertEquals("queued" to WechatStatus.INVALID_CONTENT, listener.submitted.single())
    }

    @Test fun invalidQueuedIdCannotBecomeFalseCancellation() {
        background { client.authorize("") }
        client.cancel("")
        idle()
        assertEquals(listOf("" to WechatStatus.INVALID_CONTENT), listener.submitted)
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun cancelRestoredIdAlsoSuppressesQueuedDuplicate() {
        store.saved = WechatPendingRequest("restored", "token", WechatKind.SHARE)
        background { client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", listener, store); client.authorize("restored") }
        client.cancel("restored")
        assertNull(store.saved)
        idle()
        assertEquals(listOf("restored" to WechatStatus.CANCELLED), listener.submitted)
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun storageClearFailureKeepsOwnerAndPendingWithoutFalseCancellation() {
        client.authorize("pending")
        store.failClear = true
        background { client.cancel("pending") }
        idle()
        assertEquals(listOf("pending" to WechatStatus.REQUESTED), listener.submitted)
        assertEquals("pending", store.saved?.requestId)
        client.authorize("other")
        assertEquals("other" to WechatStatus.BUSY, listener.submitted.last())
        WechatFactoryShadow.respond(authResponse())
        assertTrue(listener.receipts.isEmpty())
        store.failClear = false
        WechatFactoryShadow.respond(authResponse())
        assertEquals("pending", listener.receipts.single().requestId)
    }

    @Test fun backgroundImageAndWebShareSnapshotBytesAndFinishOnMain() {
        val bytes = image()
        background { client.shareImage("image", bytes, WechatScene.SESSION) }
        bytes.fill(0)
        awaitSubmission()
        val request = WechatFactoryShadow.sent.single() as SendMessageToWX.Req
        assertTrue((request.message.mediaObject as WXImageObject).imageData.any { it != 0.toByte() })
        assertEquals("image" to WechatStatus.REQUESTED, listener.submitted.last())
        client.cancel("image")
        val thumb = image()
        background { client.shareWebPage("web", "https://example.com", "title", "description", thumb, WechatScene.SESSION) }
        thumb.fill(0)
        awaitSubmission(3)
        assertEquals("web" to WechatStatus.REQUESTED, listener.submitted.last())
        assertEquals(2, WechatFactoryShadow.sent.size)
    }

    @Test fun specifiedContactAtMinimumVersionKeepsRecipientAndSenderSeparate() {
        WechatFactoryShadow.supportApi = Build.SEND_TO_SPECIFIED_CONTACT_SDK_INT
        client.shareImage("targeted", image(), WechatScene.SESSION, "recipient-id", "sender-id")
        awaitSubmission()
        val request = WechatFactoryShadow.sent.single() as SendMessageToWX.Req
        assertEquals(SendMessageToWX.Req.WXSceneSpecifiedContact, request.scene)
        assertEquals("recipient-id", request.userOpenId)
        assertEquals("sender-id", request.openId)
        assertTrue(request.checkArgs())
        assertEquals(listOf("targeted" to WechatStatus.REQUESTED), listener.submitted)
        assertTrue(listener.receipts.isEmpty())
    }

    @Test fun specifiedContactBelowMinimumVersionDoesNotSendOrFallBack() {
        WechatFactoryShadow.supportApi = Build.SEND_TO_SPECIFIED_CONTACT_SDK_INT - 1
        client.shareImage("old-client", image(), WechatScene.SESSION, "recipient-id", "sender-id")
        awaitSubmission()
        assertEquals(listOf("old-client" to WechatStatus.UNSUPPORTED), listener.submitted)
        assertTrue(WechatFactoryShadow.sent.isEmpty())
        assertNull(store.saved)
        assertTrue(listener.receipts.isEmpty())
    }

    @Test fun specifiedContactWithoutSenderNeverUsesRecipientAsSender() {
        for ((index, sender) in listOf(null, "", " ").withIndex()) {
            client.shareImage("missing-sender-$index", image(), WechatScene.SESSION, "recipient-id", sender)
            awaitSubmission(index + 1)
            assertEquals("missing-sender-$index" to WechatStatus.UNSUPPORTED, listener.submitted.last())
            assertNull(store.saved)
        }
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun specifiedContactRejectsBlankRecipientAndTimeline() {
        val inputs = listOf("" to WechatScene.SESSION, " " to WechatScene.SESSION, "recipient-id" to WechatScene.TIMELINE)
        for ((index, input) in inputs.withIndex()) {
            client.shareImage("invalid-target-$index", image(), input.second, input.first, "sender-id")
            awaitSubmission(index + 1)
            assertEquals("invalid-target-$index" to WechatStatus.INVALID_CONTENT, listener.submitted.last())
            assertNull(store.saved)
        }
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun ordinaryImageScenesDoNotCarrySenderOrRecipient() {
        for ((index, scene) in listOf(WechatScene.SESSION, WechatScene.TIMELINE).withIndex()) {
            val id = "ordinary-$index"
            client.shareImage(id, image(), scene, senderOpenId = "sender-id")
            awaitSubmission(index * 2 + 1)
            val request = WechatFactoryShadow.sent.last() as SendMessageToWX.Req
            assertEquals(if (scene == WechatScene.SESSION) SendMessageToWX.Req.WXSceneSession else SendMessageToWX.Req.WXSceneTimeline, request.scene)
            assertNull(request.userOpenId)
            assertNull(request.openId)
            assertEquals(id to WechatStatus.REQUESTED, listener.submitted.last())
            client.cancel(id)
        }
        assertEquals(2, WechatFactoryShadow.sent.size)
    }

    @Test fun specifiedContactSdkRejectionClearsPendingWithoutRequested() {
        WechatFactoryShadow.accepted = false
        client.shareImage("targeted-rejected", image(), WechatScene.SESSION, "recipient-id", "sender-id")
        awaitSubmission()
        assertEquals(1, WechatFactoryShadow.sent.size)
        assertEquals(listOf("targeted-rejected" to WechatStatus.FAILED), listener.submitted)
        assertNull(store.saved)
        assertTrue(listener.receipts.isEmpty())
    }

    @Test fun cancelImageWorkPreventsLateSdkSend() {
        background { client.shareImage("image", image(), WechatScene.SESSION) }
        // 只启动入队工作；图像结果即使已经排队，也不允许越过 Main cancel。
        shadowOf(Looper.getMainLooper()).runOneTask()
        client.cancel("image")
        assertEquals("image" to WechatStatus.CANCELLED, listener.submitted.last())
        finishImages()
        idle()
        assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    @Test fun rendererReceiverKeepsRealSubmissionAndSdkReceiptSeparate() {
        val module = AndroidWechatModule(client)
        val receipts = mutableListOf<JSONObject>(); val submitted = mutableListOf<String>()
        module.call("listen", "{}") { receipts += JSONObject(it as String) }
        background { module.call("authorize", "{\"requestId\":\"renderer\"}") { submitted += JSONObject(it as String).getString("status") } }
        assertTrue(submitted.isEmpty()); idle()
        assertEquals(listOf("requested"), submitted); assertTrue(receipts.isEmpty())
        WechatFactoryShadow.respond(authResponse())
        assertEquals("renderer", receipts.single().getString("requestId"))
        assertEquals("VERIFIED", receipts.single().getString("attribution"))
        assertEquals("renderer", listener.receipts.single().requestId)
        module.onDestroy()
    }
    @Test fun anotherRendererCannotTakeOwnedIdOrReceiveOldCallback() {
        val old = AndroidWechatModule(client); val next = AndroidWechatModule(client)
        val oldReplies = mutableListOf<String>(); val nextReplies = mutableListOf<String>(); var nextReceipts = 0
        old.call("listen", "{}", {})
        old.call("authorize", "{\"requestId\":\"owned\"}") { oldReplies += JSONObject(it as String).getString("status") }
        next.call("listen", "{\"restoredRequestId\":\"owned\"}") { nextReceipts++ }
        next.call("authorize", "{\"requestId\":\"owned\"}") { nextReplies += JSONObject(it as String).getString("status") }
        assertEquals(listOf("requested"), oldReplies); assertEquals(listOf("busy"), nextReplies)
        store.failClear = true
        val response = authResponse()
        old.onDestroy()
        store.failClear = false
        WechatFactoryShadow.respond(response)
        assertEquals(0, nextReceipts); assertEquals(listOf("requested"), oldReplies)
        next.onDestroy()
    }
    @Test fun receiverCancelFailureRetainsOwnerAndAckDoesNotFakeOriginalFailure() {
        val module = AndroidWechatModule(client); val receipts = mutableListOf<JSONObject>(); val ack = mutableListOf<String>(); val submitted = mutableListOf<String>()
        module.call("listen", "{}") { receipts += JSONObject(it as String) }
        module.call("authorize", "{\"requestId\":\"cancel-module\"}") { submitted += JSONObject(it as String).getString("status") }
        store.failClear = true
        module.call("cancel", "{\"requestId\":\"cancel-module\"}") { ack += JSONObject(it as String).getString("status") }
        assertEquals(listOf("failed"), ack); assertEquals(listOf("requested"), submitted)
        store.failClear = false
        WechatFactoryShadow.respond(authResponse())
        assertEquals("cancel-module", receipts.single().getString("requestId"))
        module.call("cancel", "{\"requestId\":\"cancel-module\"}") { ack += JSONObject(it as String).getString("status") }
        assertEquals(listOf("failed", "no_pending"), ack)
        module.onDestroy()
    }
    @Test fun moduleReceiptWithoutHostListenerIsNotBufferedForAnotherRenderer() {
        client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", store = store)
        val module = AndroidWechatModule(client); var receipts = 0
        module.call("listen", "{}") { receipts++ }
        module.call("authorize", "{\"requestId\":\"once-module\"}", {})
        WechatFactoryShadow.respond(authResponse())
        assertEquals(1, receipts)
        assertFalse(client.canResume("once-module"))
        val next = AndroidWechatModule(client)
        next.call("listen", "{\"restoredRequestId\":\"once-module\"}") { receipts++ }
        assertEquals(1, receipts)
        module.onDestroy(); next.onDestroy()
    }

    @Test fun receiverRestoresOnlyTrustedPendingAndDestroySuppressesQueuedSend() {
        store.saved = WechatPendingRequest("trusted-module", "token", WechatKind.AUTHORIZATION, "state")
        client = AndroidWechatClient(RuntimeEnvironment.getApplication(), "app-id", listener, store)
        val module = AndroidWechatModule(client); val receipts = mutableListOf<JSONObject>()
        module.call("listen", "{\"restoredRequestId\":\"trusted-module\"}") { receipts += JSONObject(it as String) }
        client.handleIntent(Intent())
        WechatFactoryShadow.respond(SendAuth.Resp().apply { transaction = "token"; state = "state"; code = "code"; errCode = 0 })
        assertEquals("trusted-module", receipts.single().getString("requestId"))
        module.onDestroy()
        val queued = AndroidWechatModule(client)
        background { queued.call("listen", "{}", {}); queued.call("authorize", "{\"requestId\":\"queued-module\"}", {}); queued.onDestroy() }
        idle(); assertTrue(WechatFactoryShadow.sent.isEmpty())
    }

    private fun authResponse(): SendAuth.Resp {
        client.handleIntent(Intent())
        val req = WechatFactoryShadow.sent.last { it is SendAuth.Req } as SendAuth.Req
        return SendAuth.Resp().apply { transaction = req.transaction; state = req.state; code = "server-code" }
    }
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    private fun background(action: () -> Unit) {
        var failure: Throwable? = null
        thread { try { action() } catch (error: Throwable) { failure = error } }.join()
        failure?.let { throw it }
    }
    private fun image(): ByteArray {
        val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); bitmap.recycle() }.toByteArray()
    }
    private fun finishImages() {
        // 等真实 imageExecutor 完成，不替换生产缩略图路径。
        val field = AndroidWechatClient::class.java.getDeclaredField("images").apply { isAccessible = true }
        val executor = field.get(client) as java.util.concurrent.ExecutorService
        executor.submit {}.get(5, TimeUnit.SECONDS)
    }
    private fun awaitSubmission(count: Int = 1) { idle(); finishImages(); idle(); assertEquals(count, listener.submitted.size) }
}

private fun assertMain() = assertEquals(Looper.getMainLooper(), Looper.myLooper())
private class RecordingListener : WechatListener {
    val submitted = mutableListOf<Pair<String, WechatStatus>>()
    val receipts = mutableListOf<WechatReceipt>()
    override fun onSubmitted(requestId: String, status: WechatStatus) { assertMain(); submitted.add(requestId to status) }
    override fun onReceipt(receipt: WechatReceipt) { assertMain(); receipts.add(receipt) }
}
private class MainStore : WechatRequestStore {
    var loads = 0
    var saved: WechatPendingRequest? = null
    var failClear = false
    var failSave = false
    var failLoad = false
    override fun load(): WechatPendingRequest? { assertMain(); loads++; if (failLoad) error("load failed"); return saved }
    override fun save(request: WechatPendingRequest?) { assertMain(); if (request == null && failClear || request != null && failSave) error("save failed"); saved = request }
}

@Implements(value = WXAPIFactory::class, isInAndroidSdk = false)
class WechatFactoryShadow {
    companion object {
        var created = 0
        var registrations = 0
        var registrationAccepted = true
        var handled = true
        var accepted = true
        var supportApi = 0x28002d33
        var handleFailure = false
        var response: BaseResp? = null
        private var handler: IWXAPIEventHandler? = null
        val sent = mutableListOf<BaseReq>()
        fun reset() { created = 0; registrations = 0; registrationAccepted = true; handled = true; accepted = true; supportApi = 0x28002d33; handleFailure = false; response = null; handler = null; sent.clear() }
        fun respond(resp: BaseResp) { requireNotNull(handler).onResp(resp) }
        @JvmStatic @Implementation
        fun createWXAPI(context: Context, appId: String, checkSignature: Boolean): IWXAPI {
            assertMain(); created++
            return Proxy.newProxyInstance(IWXAPI::class.java.classLoader, arrayOf(IWXAPI::class.java)) { _, method, args ->
                assertMain()
                when (method.name) {
                    "registerApp" -> { registrations++; registrationAccepted }
                    "isWXAppInstalled" -> true
                    "getWXAppSupportAPI" -> supportApi
                    "sendReq" -> { sent.add(args!![0] as BaseReq); accepted }
                    "handleIntent" -> { if (handleFailure) error("SDK handler failed"); handler = args!![1] as IWXAPIEventHandler; response?.let { handler!!.onResp(it) }; handled }
                    else -> error("Unexpected SDK call: ${method.name}")
                }
            } as IWXAPI
        }
    }
}
