package io.github.gycrosskit.wechat
import kotlin.test.*
class WechatSessionTest {
    @Test fun typesHaveIndependentCurrentRoundsAndOldCallbacksCannotConsumeReplacements() {
        val session = WechatSession()
        for (kind in WechatKind.entries) {
            val state = if (kind == WechatKind.AUTHORIZATION) "state" else null
            assertNull(session.begin(kind.name, "tx-${kind.name}", kind, state))
            assertTrue(session.finishSubmission(kind.name))
        }
        assertNull(session.begin("new-share", "tx-new-share", WechatKind.SHARE))
        assertFalse(session.cancel(WechatKind.SHARE.name))
        assertFalse(session.finishSubmission(WechatKind.SHARE.name))
        assertNull(session.consume("tx-SHARE", WechatKind.SHARE))
        assertEquals("new-share", session.consume("tx-new-share", WechatKind.SHARE)?.requestId)
        assertEquals("AUTHORIZATION", session.consume("tx-AUTHORIZATION", WechatKind.AUTHORIZATION, "state")?.requestId)
        assertEquals("MERCHANT_TRANSFER", session.consume("tx-MERCHANT_TRANSFER", WechatKind.MERCHANT_TRANSFER)?.requestId)
    }

    @Test fun imagesShareTheSameRoundButDoNotWaitForFinalReceipts() {
        val session = WechatSession()
        assertNull(session.begin("web", "web-tx", WechatKind.SHARE))
        assertNull(session.begin("image", "image-tx", WechatKind.SHARE, submissionOnly = true))
        assertNull(session.consume("web-tx", WechatKind.SHARE))
        assertNull(session.consume("image-tx", WechatKind.SHARE))
        assertTrue(session.finishSubmission("image"))
        assertFalse(session.isCurrent("image"))
        assertNull(session.begin("next", "next-tx", WechatKind.SHARE))
        assertNull(session.consume("image-tx", WechatKind.SHARE))
        assertTrue(session.isCurrent("next"))
    }

    @Test fun authorizationJournalIsNotOverwrittenOrClearedByOtherTypes() {
        val store = MemoryStore()
        val session = WechatSession(store)
        assertNull(session.begin("auth", "auth-tx", WechatKind.AUTHORIZATION, "state"))
        assertNull(session.begin("web", "web-tx", WechatKind.SHARE))
        assertNull(session.begin("transfer", "transfer-tx", WechatKind.MERCHANT_TRANSFER))
        assertNotNull(session.consume("web-tx", WechatKind.SHARE))
        assertTrue(session.cancel("transfer"))
        assertEquals("auth", store.saved?.requestId)
        assertEquals("auth", WechatSession(store).consume("auth-tx", WechatKind.AUTHORIZATION, "state")?.requestId)
        assertNull(store.saved)
    }

    @Test fun failedAuthorizationReplacementPreservesOldRoundAndOtherTypes() {
        val store = MemoryStore()
        val session = WechatSession(store)
        assertNull(session.begin("old", "old-tx", WechatKind.AUTHORIZATION, "old-state"))
        assertNull(session.begin("web", "web-tx", WechatKind.SHARE))
        store.failSave = true
        assertEquals(WechatStatus.FAILED, session.begin("new", "new-tx", WechatKind.AUTHORIZATION, "new-state"))
        assertEquals("old", session.current(WechatKind.AUTHORIZATION)?.requestId)
        assertEquals("old", store.saved?.requestId)
        assertTrue(session.isCurrent("web"))
        store.failSave = false
        assertNull(session.begin("after", "after-tx", WechatKind.AUTHORIZATION, "after-state"))
        assertFalse(session.cancel("old"))
        assertNull(session.consume("old-tx", WechatKind.AUTHORIZATION, "old-state"))
        assertEquals("after", store.saved?.requestId)
    }

    @Test fun restoredLegacyJournalCannotClearNewAuthorization() {
        val store = MemoryStore().apply { saved = WechatPendingRequest("legacy", "legacy-tx", WechatKind.SHARE) }
        val session = WechatSession(store)
        assertNull(session.begin("auth", "auth-tx", WechatKind.AUTHORIZATION, "state"))
        assertEquals("legacy", session.consume("legacy-tx", WechatKind.SHARE)?.requestId)
        assertEquals("auth", store.saved?.requestId)
        assertNotNull(session.consume("auth-tx", WechatKind.AUTHORIZATION, "state"))
    }

    @Test fun utf16BoundariesApplyToRequestIdsAndTrustedRestoration() {
        for (id in listOf("😀".repeat(65), "e\u0301".repeat(65))) {
            assertEquals(WechatStatus.INVALID_CONTENT, WechatSession().begin(id, "tx", WechatKind.AUTHORIZATION, "state"))
        }
        assertNull(WechatSession().begin("😀".repeat(64), "tx", WechatKind.AUTHORIZATION, "😀".repeat(128)))
        val boundary = WechatPendingRequest("😀".repeat(64), "tx", WechatKind.AUTHORIZATION, "😀".repeat(128))
        val boundaryStore = object : WechatRequestStore {
            override fun load() = boundary
            override fun save(request: WechatPendingRequest?) = Unit
        }
        assertEquals(boundary.requestId, WechatSession(boundaryStore).consume("tx", WechatKind.AUTHORIZATION, boundary.state)?.requestId)
        for (record in listOf(
            WechatPendingRequest("😀".repeat(65), "tx", WechatKind.AUTHORIZATION, "state"),
            WechatPendingRequest("id", "tx", WechatKind.AUTHORIZATION, "😀".repeat(129)),
        )) {
            val store = object : WechatRequestStore {
                override fun load() = record
                override fun save(request: WechatPendingRequest?) = Unit
            }
            val session = WechatSession(store)
            assertNull(session.consume(record.transaction, record.kind, record.state))
            assertNull(session.begin("fresh", "fresh-tx", WechatKind.AUTHORIZATION, "fresh-state"))
        }
    }

    @Test fun rejectsUntrustedRestorationAndReusedTransactionsWithoutLosingCurrentRequest() {
        val invalidRecords = listOf(
            WechatPendingRequest(" ", "transaction", WechatKind.SHARE),
            WechatPendingRequest("id", "transaction", WechatKind.SHARE, "unexpected-state"),
            WechatPendingRequest("id", "transaction", WechatKind.AUTHORIZATION),
            WechatPendingRequest("id", "transaction", WechatKind.AUTHORIZATION, "s".repeat(257)),
        )
        for (record in invalidRecords) {
            val session = WechatSession(object : WechatRequestStore {
                override fun load() = record
                override fun save(request: WechatPendingRequest?) = Unit
            })
            assertNull(session.consume(record.transaction, record.kind, record.state))
            assertNull(session.begin("fresh", "fresh-transaction", WechatKind.SHARE))
        }
        val session = WechatSession()
        assertEquals(WechatStatus.INVALID_CONTENT, session.begin("x".repeat(129), "tx", WechatKind.SHARE))
        assertNull(session.begin("first", "reused-transaction", WechatKind.SHARE))
        assertTrue(session.cancel("first"))
        assertEquals(WechatStatus.INVALID_CONTENT, session.begin("second", "reused-transaction", WechatKind.SHARE))
        assertNull(session.begin("second", "fresh-transaction", WechatKind.SHARE))
        assertNull(session.consume("reused-transaction", WechatKind.SHARE))
        assertTrue(session.isCurrent("second"))
        assertEquals("second", session.consume("fresh-transaction", WechatKind.SHARE)?.requestId)
    }

    @Test fun stateAndTransactionMustMatchAndOnlyConsumeOnce() {
        val s = WechatSession()
        assertNull(s.begin("one", "tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertNull(s.begin("two", "tx-two", WechatKind.SHARE))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "forged"))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, null))
        assertNull(s.consume("wrong", WechatKind.AUTHORIZATION, "secure-state"))
        assertNotNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertNull(s.consume("tx-one", WechatKind.AUTHORIZATION, "secure-state"))
        assertEquals(WechatStatus.INVALID_CONTENT, s.begin("one", "new", WechatKind.SHARE))
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
        assertNull(restored.begin("other", "other-tx", WechatKind.SHARE))
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
        assertEquals(WechatStatus.FAILED, session.begin("fail", "fail-tx", WechatKind.AUTHORIZATION, "state"))
        store.fail = false
        assertNull(session.begin("one", "one-tx", WechatKind.AUTHORIZATION, "state"))
        store.fail = true
        assertFails { session.consume("one-tx", WechatKind.AUTHORIZATION, "state") }
        assertTrue(session.isCurrent("one"))
        store.fail = false
        assertNotNull(session.consume("one-tx", WechatKind.AUTHORIZATION, "state"))
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
        assertNull(session.begin("new", "new-tx", WechatKind.SHARE))
        store.failClear = false
        assertEquals("late", session.consume("late-tx", WechatKind.AUTHORIZATION, "state")?.requestId)
        assertFalse(session.cancel("late"))
        assertNull(session.begin("retry", "retry-tx", WechatKind.AUTHORIZATION, "retry-state"))
        store.failClear = true
        assertFails { session.cancel("retry") }
        store.failClear = false
        assertTrue(session.cancel("retry"))
        assertNull(store.saved)
        assertNull(session.consume("retry-tx", WechatKind.AUTHORIZATION, "retry-state"))
    }

}

private class MemoryStore : WechatRequestStore {
    var saved: WechatPendingRequest? = null
    var failSave = false
    override fun load() = saved
    override fun save(request: WechatPendingRequest?) {
        check(!failSave)
        saved = request
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
        kotlin.test.assertEquals("e\u0301".repeat(128), wechatText("e\u0301".repeat(300), 256, 512))
        kotlin.test.assertEquals("a", wechatText("a😀", 2, 512))
    }
}

class WechatReceiptTest {
    @Test fun routingUsesSdkEvidenceWithoutPromotingCandidates() {
        val verified = WechatReceipt("original", WechatKind.SHARE, 0)
        assertEquals("original", verified.routingRequestId)
        val candidate = verified.copy(requestId = null, candidateRequestId = "candidate", attribution = WechatAttribution.SINGLE_PENDING)
        assertEquals("candidate", candidate.routingRequestId)
        assertNull(candidate.requestId)
        assertEquals(WechatAttribution.SINGLE_PENDING, candidate.attribution)
        for (kind in listOf(WechatKind.AUTHORIZATION, WechatKind.MERCHANT_TRANSFER)) {
            assertNull(candidate.copy(kind = kind).routingRequestId)
        }
        assertNull(verified.copy(attribution = WechatAttribution.UNATTRIBUTED).routingRequestId)
        assertNull(verified.copy(requestId = " ").routingRequestId)
    }

    @Test fun transferPageFactsPreserveCancellationFailureAndUnknown() {
        val cases = listOf(
            Triple(0, "success", WechatTransferPageStatus.SUCCESS),
            Triple(0, "fail", WechatTransferPageStatus.FAILED),
            Triple(-1, null, WechatTransferPageStatus.FAILED),
            Triple(-1, "success", WechatTransferPageStatus.FAILED),
            Triple(-2, "success", WechatTransferPageStatus.CANCELLED),
            Triple(-1, "cancel", WechatTransferPageStatus.CANCELLED),
            Triple(0, null, WechatTransferPageStatus.UNKNOWN),
            Triple(0, "future-result", WechatTransferPageStatus.UNKNOWN),
        )
        for ((code, page, expected) in cases) {
            assertEquals(expected, WechatTransferPageStatus.from(code, page))
            val receipt = WechatReceipt(null, WechatKind.MERCHANT_TRANSFER, code, pageResult = page)
            assertEquals(expected, receipt.transferPageStatus)
            assertNull(receipt.routingRequestId)
            assertEquals(WechatTransferPageStatus.UNKNOWN, receipt.copy(kind = WechatKind.SHARE).transferPageStatus)
        }
    }
}
