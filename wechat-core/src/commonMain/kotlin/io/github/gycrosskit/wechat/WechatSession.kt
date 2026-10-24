package io.github.gycrosskit.wechat

/** 所有访问由平台串行化到主线程；恢复记录来自宿主存储，不从回跳解析。 */
internal class WechatSession(private val store: WechatRequestStore? = null) {
    private var pending: WechatPendingRequest? = store?.load()?.takeIf(::valid)
    private var submissionOnly = false
    private val acceptedRequests = linkedMapOf<String, WechatPendingRequest>()
    private val usedIds = mutableSetOf<String>().apply { pending?.let { add(it.requestId) } }
    private val usedTransactions = mutableSetOf<String>().apply { pending?.let { add(it.transaction) } }
    fun begin(id: String, token: String, kind: WechatKind, state: String? = null, submissionOnly: Boolean = false): WechatStatus? {
        val request = WechatPendingRequest(id, token, kind, state)
        if (!valid(request) || id in usedIds || token in usedTransactions || submissionOnly && kind != WechatKind.SHARE) return WechatStatus.INVALID_CONTENT
        if (pending != null) return WechatStatus.BUSY
        usedIds.add(id); usedTransactions.add(token)
        if (!submissionOnly) try { store?.save(request) } catch (_: Exception) { return WechatStatus.FAILED }
        pending = request
        this.submissionOnly = submissionOnly
        return null
    }
    fun consume(transaction: String?, kind: WechatKind, state: String? = null): WechatPendingRequest? {
        val current = pending?.takeIf { !submissionOnly && it.kind == kind && it.transaction == transaction }
            ?: acceptedRequests.values.firstOrNull { it.kind == kind && it.transaction == transaction } ?: return null
        if (kind == WechatKind.AUTHORIZATION && current.state != state) return null
        // 清除失败时保留等待且不交付，避免进程重建重复消费。
        if (pending === current) {
            store?.save(null)
            pending = null
        } else acceptedRequests.remove(current.requestId)
        return current
    }
    fun cancel(id: String): Boolean {
        if (pending?.requestId != id) return acceptedRequests.remove(id) != null
        if (!submissionOnly) store?.save(null)
        pending = null
        submissionOnly = false
        return true
    }
    /** 网页/转账受理后共用有界回执关联，不占发送槽；持久清理失败仍保留原等待。 */
    fun finishSubmission(id: String): Boolean {
        val request = pending?.takeIf { it.requestId == id } ?: return false
        if (submissionOnly) return cancel(id)
        if (request.kind == WechatKind.AUTHORIZATION) return false
        try { store?.save(null) } catch (_: Exception) { return false }
        acceptedRequests[id] = request
        if (acceptedRequests.size > 64) acceptedRequests.remove(acceptedRequests.keys.first())
        pending = null
        return true
    }
    fun isCurrent(id: String): Boolean = pending?.requestId == id || id in acceptedRequests
    private fun valid(request: WechatPendingRequest): Boolean =
        request.requestId.isNotBlank() && request.requestId.length <= 128 &&
            request.transaction.isNotBlank() && request.transaction.length <= 128 &&
            if (request.kind == WechatKind.AUTHORIZATION) !request.state.isNullOrBlank() && request.state.length <= 256 else request.state == null
}
