package com.tencent.kuikly.core.nvi.serialization.json

/** 只替代 JSON 容器；测试执行库里的 WechatModule，而非复制其取消逻辑。 */
class JSONObject {
    private val values = mutableMapOf<String, Any>()
    fun put(key: String, value: Any) { values[key] = value }
    fun optString(key: String) = values[key] as? String ?: ""
    fun optInt(key: String) = values[key] as? Int ?: 0
    override fun toString() = values.toString()
}
