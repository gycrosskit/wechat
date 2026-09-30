import Foundation

// 单次 SDK 发送与 OAuth 等待单独管理；分享/转账响应不具备请求标识，不能结束任何请求。
final class WechatSession {
    private var usedIDs = Set<String>()
    private var submitting: String?
    private var authorization: (id: String, state: String)?
    func begin(_ id: String, state: String? = nil) -> String? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 128, !usedIDs.contains(id) else { return "invalid_content" }
        guard submitting == nil, authorization == nil else { return "busy" }
        usedIDs.insert(id)
        submitting = id
        if let state { authorization = (id, state) }
        return nil
    }
    func submitted(_ id: String, accepted: Bool) -> Bool {
        guard submitting == id else { return false }
        submitting = nil
        if !accepted, authorization?.id == id { authorization = nil }
        return true
    }
    func consumeAuthorization(_ state: String?) -> String? {
        guard let auth = authorization, state == auth.state else { return nil }
        authorization = nil
        return auth.id
    }
    func cancel(_ id: String) -> Bool {
        let active = submitting == id || authorization?.id == id
        if submitting == id { submitting = nil }
        if authorization?.id == id { authorization = nil }
        return active
    }
}
