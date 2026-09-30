package io.github.gycrosskit.wechat

/** 所有访问都由平台串行化到主线程；精确匹配 SDK transaction 和 OAuth state。 */
internal class WechatSession {
    data class Pending(val id: String, val transaction: String, val kind: WechatKind, val state: String?)
    private var pending: Pending? = null
    private val usedIds = mutableSetOf<String>()
    fun begin(id: String, token: String, kind: WechatKind, state: String? = null): WechatStatus? {
        if (id.isBlank() || id.length > 128 || token.isBlank() || (kind == WechatKind.AUTHORIZATION && state.isNullOrBlank())) return WechatStatus.INVALID_CONTENT
        if (pending != null) return WechatStatus.BUSY
        // 不淘汰 requestId，防止宿主复用 ID 后旧回调结束新请求。SDK 实例按进程持有。
        if (!usedIds.add(id)) return WechatStatus.INVALID_CONTENT
        pending = Pending(id, token, kind, state)
        return null
    }
    fun consume(transaction: String?, kind: WechatKind, state: String? = null): Pending? {
        val current = pending ?: return null
        if (current.kind != kind || current.transaction != transaction) return null
        // 包括取消和失败在内也要求 state，缺失 state 的旧 SDK 回调只能由宿主取消等待。
        if (kind == WechatKind.AUTHORIZATION && current.state != state) return null
        pending = null
        return current
    }
    fun cancel(id: String): Boolean {
        if (pending?.id != id) return false
        pending = null
        return true
    }
    fun isCurrent(id: String): Boolean = pending?.id == id
}
