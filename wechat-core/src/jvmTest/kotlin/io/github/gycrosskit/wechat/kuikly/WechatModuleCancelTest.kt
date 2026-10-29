package io.github.gycrosskit.wechat.kuikly

import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.wechat.*
import kotlin.test.*
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout

class WechatModuleCancelTest {
    private class Listener : WechatListener {
        val submitted = mutableListOf<Pair<String, WechatStatus>>()
        val receipts = mutableListOf<WechatReceipt>()
        override fun onSubmitted(requestId: String, status: WechatStatus) { submitted += requestId to status }
        override fun onReceipt(receipt: WechatReceipt) { receipts += receipt }
    }
    private fun status(value: String) = JSONObject().apply { put("status", value) }
    private fun receipt(id: String) = JSONObject().apply {
        put("requestId", id); put("kind", "authorization"); put("errorCode", 0); put("authorizationCode", "code")
    }

    @Test fun base64ImagesCrossBridgeWithoutDecodingOrReencodingAndRespectCallerLimit() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        val valid = listOf("AQ==", "AQ", " A Q = = ", "data:image/png;base64,AQ==")
        for ((index, data) in valid.withIndex()) {
            module.shareImageBase64("valid-$index", data, WechatScene.SESSION, "recipient", "sender", maximumBytes = 1)
            val call = module.calls.last()
            assertEquals("image", call.method)
            assertTrue(call.params.toString().contains("data=AQ=="))
            assertTrue(call.params.toString().contains("recipientId=recipient"))
            call.deliver(status("requested"))
        }
        val calls = module.calls.size
        for (data in listOf("", "!", "A", "A=Q=", "AQ=", "AQ===", "data:image/png,AQ==", "data:" + "x".repeat(257) + ";base64,AQ==", "AQID")) {
            module.shareImageBase64("invalid-${listener.submitted.size}", data, WechatScene.SESSION, maximumBytes = 1)
            assertEquals(WechatStatus.INVALID_CONTENT, listener.submitted.last().second)
            assertEquals(calls, module.calls.size)
        }
        for (limit in listOf(0, 25 * 1024 * 1024 + 1)) {
            module.shareImageBase64("limit-$limit", "AQ==", WechatScene.SESSION, maximumBytes = limit)
            assertEquals(WechatStatus.INVALID_CONTENT, listener.submitted.last().second)
        }
        module.dispose()
    }

    @Test fun replacementControlResumesOldWaitWithoutEndingAnotherType() = runBlocking {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        val old = async(start = CoroutineStart.UNDISPATCHED) {
            module.awaitSubmission("old", WechatKind.AUTHORIZATION) { authorize("old") }
        }
        val other = async(start = CoroutineStart.UNDISPATCHED) {
            module.awaitSubmission("other", WechatKind.MERCHANT_TRANSFER) { openMerchantTransfer("other", "m", "app", "package") }
        }
        val otherCall = module.calls.last()
        module.calls.first().deliver(status("cancelled").apply { put("requestId", "old") })
        assertEquals(WechatStatus.CANCELLED, withTimeout(1_000) { old.await() })
        assertFalse(other.isCompleted)
        otherCall.deliver(status("requested"))
        assertEquals(WechatStatus.REQUESTED, withTimeout(1_000) { other.await() })
        assertTrue(listener.receipts.isEmpty())
        module.dispose()
    }

    @Test fun replacementControlEndsOnlyOldSubmissionWithoutFakingReceipt() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        module.authorize("old"); module.authorize("new")
        val currentCallback = module.calls.last().callbackRef
        module.calls.first().deliver(status("cancelled").apply { put("requestId", "old") })
        assertEquals(listOf("old" to WechatStatus.CANCELLED), listener.submitted)
        assertTrue(listener.receipts.isEmpty())
        assertTrue(currentCallback in module.liveCallbacks)
        module.dispose()
    }

    @Test fun iosCandidateDoesNotBecomeVerifiedRequestId() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        module.calls.single().deliver(JSONObject().apply {
            put("kind", "share"); put("errorCode", 0); put("candidateRequestId", "candidate"); put("attribution", "SINGLE_PENDING")
        })
        val value = listener.receipts.single()
        assertNull(value.requestId); assertEquals("candidate", value.candidateRequestId)
        assertEquals(WechatAttribution.SINGLE_PENDING, value.attribution)
        module.dispose()
    }

    @Test fun explicitUnknownAttributionIsNeverPromotedToVerified() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        module.calls.single().deliver(receipt("id").apply { put("attribution", "future_unknown") })
        assertEquals(WechatAttribution.UNATTRIBUTED, listener.receipts.single().attribution)
        module.dispose()
    }

    @Test fun failedCancelRetainsSubmissionAndLateReceiptWithoutFalseTerminalStatus() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        val listen = module.calls.single(); module.authorize("original")
        val submit = module.calls.last(); module.cancel("original")
        module.calls.last().deliver(status("failed"))
        assertTrue(listener.submitted.isEmpty())
        assertEquals(setOf(listen.callbackRef, submit.callbackRef), module.liveCallbacks)
        submit.deliver(status("requested"))
        listen.deliver(receipt("original"))
        assertEquals(listOf("original" to WechatStatus.REQUESTED), listener.submitted)
        assertEquals("original", listener.receipts.single().requestId)
        module.cancel("original"); module.calls.last().deliver(status("no_pending"))
        assertEquals(1, listener.submitted.size)
        assertEquals(setOf(listen.callbackRef), module.liveCallbacks)
        module.dispose(); assertTrue(module.liveCallbacks.isEmpty())
    }

    @Test fun failedCancelCanRetryAndSuccessReleasesOriginalSubmission() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        module.authorize("retry"); module.cancel("retry")
        module.calls.last().deliver(status("failed"))
        module.cancel("retry"); module.calls.last().deliver(status("cancelled"))
        assertEquals(listOf("retry" to WechatStatus.CANCELLED), listener.submitted)
        assertEquals(1, module.liveCallbacks.size)
        module.dispose(); assertTrue(module.liveCallbacks.isEmpty())
    }

    @Test fun synchronousCancelAcksReleaseAllBranchesAndPermitRetry() {
        for (result in listOf("failed", "no_pending", "cancelled")) {
            val module = WechatModule(); val listener = Listener(); module.attach(listener)
            module.synchronousCancelStatus = result
            module.cancel("id"); module.cancel("id")
            assertEquals(2, module.calls.count { it.method == "cancel" })
            assertEquals(1, module.liveCallbacks.size)
            assertEquals(if (result == "cancelled") 2 else 0, listener.submitted.size)
            module.dispose(); assertTrue(module.liveCallbacks.isEmpty())
        }
    }

    @Test fun disposeReleasesQueuedAckAndIgnoresItsLateClosure() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        module.authorize("destroyed"); module.cancel("destroyed")
        val queued = module.calls.last(); module.dispose()
        assertTrue(module.liveCallbacks.isEmpty())
        queued.deliver(status("cancelled"))
        module.cancel("destroyed")
        assertTrue(listener.submitted.isEmpty())
        assertTrue(module.liveCallbacks.isEmpty())
        assertEquals(1, module.calls.count { it.method == "cancel" })
    }

    @Test fun pendingSubmissionAckPreservesReceiptOwnerWithoutFailedTerminal() {
        val module = WechatModule(); val listener = Listener(); module.attach(listener)
        val listen = module.calls.single(); module.authorize("pending")
        module.calls.last().deliver(status("pending"))
        assertTrue(listener.submitted.isEmpty())
        assertEquals(setOf(listen.callbackRef), module.liveCallbacks)
        listen.deliver(receipt("pending"))
        assertEquals("pending", listener.receipts.single().requestId)
        module.dispose(); assertTrue(module.liveCallbacks.isEmpty())
    }
}
