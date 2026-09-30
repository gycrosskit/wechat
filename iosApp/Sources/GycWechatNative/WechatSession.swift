import Foundation

public struct WechatPendingAuthorization {
    public let requestID: String
    public let state: String
    public init(requestID: String, state: String) { self.requestID = requestID; self.state = state }
}

/// 同一 App 的可信本地记录；同步原子保存，取消/消费必须清除。不能从回跳 URL 恢复 state。
public protocol WechatAuthorizationStore {
    func load() throws -> WechatPendingAuthorization?
    func save(_ request: WechatPendingAuthorization?) throws
}

// 单次 SDK 发送与 OAuth 等待单独管理；分享/转账响应不具备请求标识，不能结束任何请求。
final class WechatSession {
    private var usedIDs = Set<String>()
    private var submitting: String?
    private var authorization: WechatPendingAuthorization?
    private let store: WechatAuthorizationStore?
    private var restorationFailed = false
    init(store: WechatAuthorizationStore? = nil) {
        self.store = store
        do {
            if let saved = try store?.load(), Self.valid(saved) {
                authorization = saved; usedIDs.insert(saved.requestID)
            }
        } catch { restorationFailed = true }
    }
    private static func valid(_ request: WechatPendingAuthorization) -> Bool {
        !request.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.requestID.count <= 128 &&
            !request.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.state.count <= 256
    }
    func begin(_ id: String, state: String? = nil) -> String? {
        guard !restorationFailed else { return "failed" }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.count <= 128, !usedIDs.contains(id) else { return "invalid_content" }
        guard submitting == nil, authorization == nil else { return "busy" }
        usedIDs.insert(id)
        if let state {
            let request = WechatPendingAuthorization(requestID: id, state: state)
            guard Self.valid(request) else { return "invalid_content" }
            do { try store?.save(request) } catch { return "failed" }
            authorization = request
        }
        submitting = id
        return nil
    }
    func submitted(_ id: String, accepted: Bool) -> Bool {
        guard submitting == id else { return false }
        submitting = nil
        if !accepted, authorization?.requestID == id {
            do { try store?.save(nil) } catch { return false }
            authorization = nil
        }
        return true
    }
    func consumeAuthorization(_ state: String?) -> String? {
        guard let auth = authorization, state == auth.state else { return nil }
        do { try store?.save(nil) } catch { return nil }
        authorization = nil
        return auth.requestID
    }
    func cancel(_ id: String) -> Bool {
        let active = submitting == id || authorization?.requestID == id
        if authorization?.requestID == id {
            do { try store?.save(nil) } catch { return false }
        }
        if submitting == id { submitting = nil }
        if authorization?.requestID == id { authorization = nil }
        return active
    }
}
