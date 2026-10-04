package io.github.gycrosskit.wechat.kuikly

import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.wechat.*
import kotlin.test.*

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
