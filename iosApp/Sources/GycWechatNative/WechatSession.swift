import Foundation

/// 同一 App 可信的授权等待记录；不从回跳 URL 构造或打印随机 state。
public struct WechatPendingAuthorization {
    /// 宿主非空唯一 ID，最多 128 个 UTF-16 单元。
    public let requestID: String
    /// 组件产生的非空随机 state，最多 256 个 UTF-16 单元；仅用于回执关联。
    public let state: String
    /// 构造可信快照；Session 在加载或开始时核验长度和非空。
    public init(requestID: String, state: String) { self.requestID = requestID; self.state = state }
}

/// 同一 App 的可信本地记录；同步原子保存，取消/消费必须清除。不能从回跳 URL 恢复 state。
public protocol WechatAuthorizationStore {
    /// 同步读取唯一等待；异常会阻止覆写未知旧 journal。
    func load() throws -> WechatPendingAuthorization?
    /// 原子保存；nil 持久清除，失败必须抛错并阻止消费。
    func save(_ request: WechatPendingAuthorization?) throws
}

// SDK 无分享 transaction；单笔候选只能帮助投递，不能证明回执归属。
final class WechatSession {
    enum ShareMode { case submissionOnly, tracked }
    private enum Kind { case authorization, share, merchantTransfer }
    private struct Current {
        let id: String
        var state: String? = nil
        var sharing: ShareMode? = nil
        var dispatched = false
        var submitting = true
    }
    private var usedIDs = Set<String>()
    private var current: [Kind: Current] = [:]
    private var shareAttributionUncertain = false
    var canCorrelateShareReceipt: Bool {
        !shareAttributionUncertain && !(current[.share]?.sharing == .submissionOnly && current[.share]?.dispatched == true)
    }
    private let store: WechatAuthorizationStore?
    private var restorationFailed = false
    init(store: WechatAuthorizationStore? = nil) {
        self.store = store
        do {
            if let saved = try store?.load(), Self.valid(saved) {
                current[.authorization] = Current(id: saved.requestID, state: saved.state, submitting: false)
                usedIDs.insert(saved.requestID)
            }
        } catch { restorationFailed = true }
    }
    private static func valid(_ request: WechatPendingAuthorization) -> Bool {
        !request.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.requestID.utf16.count <= 128 &&
            !request.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.state.utf16.count <= 256
    }
    func begin(_ id: String, state: String? = nil, sharing: ShareMode? = nil, onReplaced: ((String) -> Void)? = nil) -> String? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 128, !usedIDs.contains(id) else { return "invalid_content" }
        usedIDs.insert(id)
        let kind: Kind = state != nil ? .authorization : sharing != nil ? .share : .merchantTransfer
        if let state {
            guard !restorationFailed else { return "failed" }
            let request = WechatPendingAuthorization(requestID: id, state: state)
            guard Self.valid(request) else { return "invalid_content" }
            // 一次原子覆写；失败时旧 state 和当前轮均不变。
            do { try store?.save(request) } catch { return "failed" }
        }
        let previous = current[kind]
        if kind == .share, previous?.dispatched == true { shareAttributionUncertain = true }
        current[kind] = Current(id: id, state: state, sharing: sharing)
        // 先使旧轮失效，回调可以再次发起同类请求。
        if let previous { onReplaced?(previous.id) }
        return nil
    }
    func isSubmitting(_ id: String) -> Bool { current.values.contains { $0.id == id && $0.submitting } }
    func submitted(_ id: String, accepted: Bool) -> Bool {
        guard let (kind, pending) = current.first(where: { $0.value.id == id && $0.value.submitting }) else { return false }
        if kind == .authorization, !accepted {
            do { try store?.save(nil) } catch { return false }
        }
        if kind == .share, accepted, pending.sharing == .submissionOnly { shareAttributionUncertain = true }
        if !accepted || kind == .merchantTransfer || kind == .share && (pending.sharing == .submissionOnly || shareAttributionUncertain) {
            current.removeValue(forKey: kind)
        } else {
            current[kind]?.submitting = false
        }
        return true
    }
    @discardableResult func dispatchedShare(_ id: String) -> Bool {
        guard current[.share]?.id == id, current[.share]?.submitting == true else { return false }
        current[.share]?.dispatched = true
        return true
    }
    var submittingShare: Bool { current[.share]?.submitting == true }
    func submittingAuthorization(_ state: String?) -> Bool {
        current[.authorization]?.state == state && current[.authorization]?.submitting == true
    }
    func consumeShare() -> String? {
        if current[.share]?.sharing == .submissionOnly, current[.share]?.dispatched == true { shareAttributionUncertain = true }
        guard !shareAttributionUncertain, let pending = current[.share], pending.sharing == .tracked, pending.dispatched else { return nil }
        current.removeValue(forKey: .share)
        return pending.id
    }
    func consumeAuthorization(_ state: String?) -> String? {
        guard let auth = current[.authorization], state == auth.state else { return nil }
        do { try store?.save(nil) } catch { return nil }
        current.removeValue(forKey: .authorization)
        return auth.id
    }
    func isCurrent(_ id: String) -> Bool { current.values.contains { $0.id == id } }
    func canResume(_ id: String) -> Bool { current[.authorization]?.id == id }
    func cancel(_ id: String) -> Bool {
        guard let (kind, pending) = current.first(where: { $0.value.id == id }) else { return false }
        if kind == .authorization {
            do { try store?.save(nil) } catch { return false }
        }
        if kind == .share, pending.dispatched { shareAttributionUncertain = true }
        current.removeValue(forKey: kind)
        return true
    }
}

/** 与 Kotlin 同样按 UTF-16 上限截断，再满足厂商 UTF-8 字节上限，保留完整 surrogate。 */
func wechatText(_ value: String, characters: Int, bytes: Int) -> String {
    let source = value as NSString
    var end = min(characters, source.length)
    while end > 0 {
        if !(0xD800...0xDBFF).contains(source.character(at: end - 1)) {
            let text = source.substring(to: end)
            if text.utf8.count <= bytes { return text }
        }
        end -= 1
    }
    return ""
}
