package io.github.gycrosskit.wechat

/** 平台在 Main 串行访问；每种能力只保留当前一轮，回跳不能创建可信请求。 */
internal class WechatSession(private val store: WechatRequestStore? = null) {
    private class Entry(val request: WechatPendingRequest, val submissionOnly: Boolean = false)
    // 兼容旧版保存的非 OAuth 请求；新请求仅持久化授权，不覆盖另一类型的授权记录。
    private var journal = store?.load()?.takeIf(::valid)
    private val current = mutableMapOf<WechatKind, Entry>().apply {
        journal?.let { put(it.kind, Entry(it)) }
    }
    private val usedIds = mutableSetOf<String>().apply { journal?.let { add(it.requestId) } }
    private val usedTransactions = mutableSetOf<String>().apply { journal?.let { add(it.transaction) } }

    fun current(kind: WechatKind): WechatPendingRequest? = current[kind]?.request

    /** 保存成功才替换旧轮；失败不能抹掉旧 OAuth 的可信关联。 */
    fun begin(id: String, token: String, kind: WechatKind, state: String? = null, submissionOnly: Boolean = false): WechatStatus? {
        val request = WechatPendingRequest(id, token, kind, state)
        if (!valid(request) || id in usedIds || token in usedTransactions || submissionOnly && kind != WechatKind.SHARE) return WechatStatus.INVALID_CONTENT
        usedIds.add(id); usedTransactions.add(token)
        try {
            if (kind == WechatKind.AUTHORIZATION) {
                store?.save(request)
                journal = request
            } else if (journal != null && journal === current[kind]?.request) {
                store?.save(null)
                journal = null
            }
        } catch (_: Exception) { return WechatStatus.FAILED }
        current[kind] = Entry(request, submissionOnly)
        return null
    }

    fun consume(transaction: String?, kind: WechatKind, state: String? = null): WechatPendingRequest? {
        val entry = current[kind]?.takeIf { !it.submissionOnly && it.request.transaction == transaction } ?: return null
        if (kind == WechatKind.AUTHORIZATION && entry.request.state != state) return null
        remove(entry)
        return entry.request
    }

    fun cancel(id: String): Boolean {
        val entry = current.values.firstOrNull { it.request.requestId == id } ?: return false
        remove(entry)
        return true
    }

    /** 图片仅交付受理结果；其余类型仍只保留本轮，不另建已受理历史集合。 */
    fun finishSubmission(id: String): Boolean {
        val entry = current.values.firstOrNull { it.request.requestId == id } ?: return false
        if (entry.submissionOnly) remove(entry)
        return true
    }

    fun isCurrent(id: String): Boolean = current.values.any { it.request.requestId == id }

    private fun remove(entry: Entry) {
        if (journal === entry.request) {
            store?.save(null)
            journal = null
        }
        current.remove(entry.request.kind)
    }

    private fun valid(request: WechatPendingRequest): Boolean =
        request.requestId.isNotBlank() && request.requestId.length <= 128 &&
            request.transaction.isNotBlank() && request.transaction.length <= 128 &&
            if (request.kind == WechatKind.AUTHORIZATION) !request.state.isNullOrBlank() && request.state.length <= 256 else request.state == null
}
