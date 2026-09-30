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
}
