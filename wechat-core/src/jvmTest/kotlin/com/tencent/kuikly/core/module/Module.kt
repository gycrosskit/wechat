package com.tencent.kuikly.core.module

import com.tencent.kuikly.core.nvi.serialization.json.JSONObject

typealias CallbackRef = Int

/** Kuikly 的 once callback 返回后释放；保留 queued 闭包以验证 dispose 门禁。 */
abstract class Module {
    data class ReturnValue(val callbackRef: CallbackRef?)
    data class Call(val method: String, val callbackRef: CallbackRef?, val deliver: (JSONObject?) -> Unit)
    val calls = mutableListOf<Call>()
    val liveCallbacks = mutableSetOf<CallbackRef>()
    var synchronousCancelStatus: String? = null
    private var nextRef = 0
    abstract fun moduleName(): String
    fun toNative(keepCallbackAlive: Boolean, method: String, params: Any?, callback: ((JSONObject?) -> Unit)?, syncCall: Boolean): ReturnValue {
        val ref = if (callback != null) ++nextRef else null
        ref?.let(liveCallbacks::add)
        val call = Call(method, ref) { payload ->
            callback?.invoke(payload)
            if (!keepCallbackAlive) ref?.let(liveCallbacks::remove)
        }
        calls += call
        if (method == "cancel") synchronousCancelStatus?.let { status ->
            call.deliver(JSONObject().apply { put("status", status) })
        }
        return ReturnValue(ref)
    }
    fun removeCallback(ref: CallbackRef) { liveCallbacks.remove(ref) }
}
