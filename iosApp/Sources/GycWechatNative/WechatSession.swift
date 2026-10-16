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

// ponytail: 单笔本地候选无法辨认不同 URL 重复回执；需要严格证明时由宿主核验，SDK 无 transaction。
final class WechatSession {
    private var usedIDs = Set<String>()
    private var submitting: String?
    enum ShareMode { case submissionOnly, tracked }
    private var share: (id: String, mode: ShareMode, dispatched: Bool)?
    private var shareAttributionUncertain = false
    var canCorrelateShareReceipt: Bool { !shareAttributionUncertain }
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
        !request.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.requestID.utf16.count <= 128 &&
            !request.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.state.utf16.count <= 256
    }
    func begin(_ id: String, state: String? = nil, sharing: ShareMode? = nil) -> String? {
        guard !restorationFailed else { return "failed" }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 128, !usedIDs.contains(id) else { return "invalid_content" }
        guard submitting == nil, authorization == nil, share == nil else { return "busy" }
        usedIDs.insert(id)
        if let state {
            let request = WechatPendingAuthorization(requestID: id, state: state)
            guard Self.valid(request) else { return "invalid_content" }
            do { try store?.save(request) } catch { return "failed" }
            authorization = request
        }
        if let sharing { share = (id, sharing, false) }
        submitting = id
        return nil
    }
    func submitted(_ id: String, accepted: Bool) -> Bool {
        guard submitting == id else { return false }
        submitting = nil
        if share?.id == id, !accepted || share?.mode == .submissionOnly || shareAttributionUncertain { share = nil }
        if !accepted, authorization?.requestID == id {
            do { try store?.save(nil) } catch { return false }
            authorization = nil
        }
        return true
    }
    @discardableResult func dispatchedShare(_ id: String) -> Bool {
        guard submitting == id, share?.id == id else { return false }
        share?.dispatched = true
        // shortcut: SDK 无 transaction，图片交 SDK 后迟回执无法与后续网页区分，SDK 提供标识后再解除。
        if share?.mode == .submissionOnly { shareAttributionUncertain = true }
        return true
    }
    func consumeShare() -> String? {
        guard !shareAttributionUncertain, let pending = share, pending.mode == .tracked, pending.dispatched else { return nil }
        share = nil
        return pending.id
    }
    func consumeAuthorization(_ state: String?) -> String? {
        guard let auth = authorization, state == auth.state else { return nil }
        do { try store?.save(nil) } catch { return nil }
        authorization = nil
        return auth.requestID
    }
    func canResume(_ id: String) -> Bool { authorization?.requestID == id }
    func cancel(_ id: String) -> Bool {
        let active = submitting == id || authorization?.requestID == id || share?.id == id
        if authorization?.requestID == id {
            do { try store?.save(nil) } catch { return false }
        }
        if share?.id == id {
            if share?.dispatched == true { shareAttributionUncertain = true }
            share = nil
        }
        if submitting == id { submitting = nil }
        if authorization?.requestID == id { authorization = nil }
        return active
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
