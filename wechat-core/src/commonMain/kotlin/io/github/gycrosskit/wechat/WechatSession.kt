package io.github.gycrosskit.wechat

/** 所有访问由平台串行化到主线程；恢复记录来自宿主存储，不从回跳解析。 */
internal class WechatSession(private val store: WechatRequestStore? = null) {
    private var pending: WechatPendingRequest? = store?.load()?.takeIf(::valid)
    private val usedIds = mutableSetOf<String>().apply { pending?.let { add(it.requestId) } }
    private val usedTransactions = mutableSetOf<String>().apply { pending?.let { add(it.transaction) } }
    fun begin(id: String, token: String, kind: WechatKind, state: String? = null): WechatStatus? {
        val request = WechatPendingRequest(id, token, kind, state)
        if (!valid(request) || id in usedIds || token in usedTransactions) return WechatStatus.INVALID_CONTENT
        if (pending != null) return WechatStatus.BUSY
        usedIds.add(id); usedTransactions.add(token)
        try { store?.save(request) } catch (_: Exception) { return WechatStatus.FAILED }
        pending = request
        return null
    }
    fun consume(transaction: String?, kind: WechatKind, state: String? = null): WechatPendingRequest? {
        val current = pending ?: return null
        if (current.kind != kind || current.transaction != transaction) return null
        if (kind == WechatKind.AUTHORIZATION && current.state != state) return null
        // 清除失败时保留等待且不交付，避免进程重建重复消费。
        store?.save(null)
        pending = null
        return current
    }
    fun cancel(id: String): Boolean {
        if (pending?.requestId != id) return false
        store?.save(null)
        pending = null
        return true
    }
    fun isCurrent(id: String): Boolean = pending?.requestId == id
    private fun valid(request: WechatPendingRequest): Boolean =
        request.requestId.isNotBlank() && request.requestId.length <= 128 &&
            request.transaction.isNotBlank() && request.transaction.length <= 128 &&
            if (request.kind == WechatKind.AUTHORIZATION) !request.state.isNullOrBlank() && request.state.length <= 256 else request.state == null
}
