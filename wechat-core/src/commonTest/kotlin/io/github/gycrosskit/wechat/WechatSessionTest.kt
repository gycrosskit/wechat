package io.github.gycrosskit.wechat
import kotlin.test.*
class WechatSessionTest {
    @Test fun stateAndTransactionMustMatchAndOnlyConsumeOnce() {
        val s = WechatSession()
        assertNull(s.begin("one", "tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertEquals(WechatStatus.BUSY, s.begin("two", "tx-two", WechatKind.SHARE))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "forged"))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, null))
        assertNull(s.consume("wrong", WechatKind.AUTHORIZATION, "secure-state"))
        assertNotNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertEquals(WechatStatus.INVALID_CONTENT, s.begin("one", "new", WechatKind.SHARE))
        assertNull(s.begin("two", "tx-two", WechatKind.SHARE))
        assertFalse(s.cancel("one"))
        assertTrue(s.cancel("two"))
        assertNull(s.begin("three", "tx-three", WechatKind.SHARE))
        assertNull(s.consume("tx-two", WechatKind.SHARE))
        assertNotNull(s.consume("tx-three", WechatKind.SHARE))
    }
    @Test fun trustedJournalSurvivesProcessRecreationAndCannotReviveCancelledRequests() {
        val store = object : WechatRequestStore {
            var saved: WechatPendingRequest? = null
            override fun load() = saved
            override fun save(request: WechatPendingRequest?) { saved = request }
        }
        assertNull(WechatSession(store).begin("cold", "random-transaction", WechatKind.AUTHORIZATION, "secret-state"))
        val restored = WechatSession(store)
        assertEquals(WechatStatus.BUSY, restored.begin("other", "other-tx", WechatKind.SHARE))
        assertNull(restored.consume("unknown", WechatKind.AUTHORIZATION, "secret-state"))
        assertNull(restored.consume("random-transaction", WechatKind.SHARE))
        assertNull(restored.consume("random-transaction", WechatKind.AUTHORIZATION, "forged"))
        assertEquals("cold", restored.consume("random-transaction", WechatKind.AUTHORIZATION, "secret-state")?.requestId)
        assertNull(store.saved)
        assertNull(WechatSession(store).consume("random-transaction", WechatKind.AUTHORIZATION, "secret-state"))
        assertNull(restored.begin("cancelled", "cancel-tx", WechatKind.SHARE))
        assertTrue(restored.cancel("cancelled"))
        assertNull(WechatSession(store).consume("cancel-tx", WechatKind.SHARE))
        store.saved = WechatPendingRequest("invalid", "", WechatKind.SHARE)
        assertNull(WechatSession(store).consume("", WechatKind.SHARE))
    }
    @Test fun journalFailuresBlockSendingAndDelivery() {
        val store = object : WechatRequestStore {
            var fail = true
            override fun load(): WechatPendingRequest? = null
            override fun save(request: WechatPendingRequest?) { check(!fail) }
        }
        val session = WechatSession(store)
        assertEquals(WechatStatus.FAILED, session.begin("fail", "fail-tx", WechatKind.SHARE))
        store.fail = false
        assertNull(session.begin("one", "one-tx", WechatKind.SHARE))
        store.fail = true
        assertFails { session.consume("one-tx", WechatKind.SHARE) }
        assertTrue(session.isCurrent("one"))
        store.fail = false
        assertNotNull(session.consume("one-tx", WechatKind.SHARE))
    }

    @Test fun failedCancelKeepsTrustedPendingForLateReceiptOrRetry() {
        val store = object : WechatRequestStore {
            var saved: WechatPendingRequest? = null
            var failClear = false
            override fun load() = saved
            override fun save(request: WechatPendingRequest?) {
                check(request != null || !failClear)
                saved = request
            }
        }
        val session = WechatSession(store)
        assertNull(session.begin("late", "late-tx", WechatKind.AUTHORIZATION, "state"))
        store.failClear = true
        assertFalse(session.cancel("unknown"))
        assertFails { session.cancel("late") }
        assertTrue(session.isCurrent("late"))
        assertEquals("late", store.saved?.requestId)
        assertEquals(WechatStatus.BUSY, session.begin("new", "new-tx", WechatKind.SHARE))
        store.failClear = false
        assertEquals("late", session.consume("late-tx", WechatKind.AUTHORIZATION, "state")?.requestId)
        assertFalse(session.cancel("late"))
        assertNull(session.begin("retry", "retry-tx", WechatKind.SHARE))
        store.failClear = true
        assertFails { session.cancel("retry") }
        store.failClear = false
        assertTrue(session.cancel("retry"))
        assertNull(store.saved)
        assertNull(session.consume("retry-tx", WechatKind.SHARE))
    }

}

class WechatShareContentTest {
    @kotlin.test.Test fun keepsHostLimitsWithinSdkBytes() {
        kotlin.test.assertEquals(25 * 1024 * 1024, MAX_WECHAT_IMAGE)
        kotlin.test.assertEquals("a".repeat(256), wechatText("a".repeat(300), 256, 512))
        kotlin.test.assertEquals("中".repeat(170), wechatText("中".repeat(256), 256, 512))
        kotlin.test.assertEquals("文".repeat(341), wechatText("文".repeat(512), 512, 1024))
        val emoji = wechatText("😀".repeat(300), 256, 512)
        kotlin.test.assertTrue(emoji.encodeToByteArray().size <= 512)
        kotlin.test.assertFalse(emoji.last().isHighSurrogate())
        kotlin.test.assertEquals("", wechatText("", 256, 512))
    }
}
