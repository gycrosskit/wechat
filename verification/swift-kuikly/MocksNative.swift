import Foundation
// Count system observer resources independently of the receiver's private state.
final class NotificationCenter {
    static let `default` = NotificationCenter()
    private final class Token: NSObject {
        let name: Notification.Name
        let action: (Notification) -> Void
        init(_ name: Notification.Name, _ action: @escaping (Notification) -> Void) { self.name = name; self.action = action }
    }
    private var tokens = [ObjectIdentifier: Token]()
    var observerCount: Int { tokens.count }
    func addObserver(forName name: Notification.Name?, object: Any?, queue: OperationQueue?, using action: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let token = Token(name!, action); tokens[ObjectIdentifier(token)] = token; return token
    }
    func removeObserver(_ observer: Any) { if let token = observer as? Token { tokens.removeValue(forKey: ObjectIdentifier(token)) } }
    func post(name: Notification.Name, object: Any?) {
        for token in Array(tokens.values) where token.name == name { token.action(Notification(name: name, object: object)) }
    }
}
public enum WechatScene { case session, timeline }
public enum WechatKind { case authorization, share, merchantTransfer }
public enum WechatAttribution { case verified, singlePending, unattributed }
public struct WechatReceipt {
    public let requestID: String?; public let candidateRequestID: String?; public let kind: WechatKind; public let errorCode: Int32
    public let authorizationCode: String? = nil; public let pageResult: String? = nil; public let attribution: WechatAttribution
}
public final class WechatClient {
    struct Observer { let owns: (String) -> Bool; let submitted: (String, String) -> Void; let receipt: (WechatReceipt) -> Void }
    var observers = [UUID: Observer](); var starts = [String](); var cancelled = [String](); var cancellationSucceeds = true; var cancellationHasPending = true
    var pending = Set<String>()
    var trusted = Set<String>(); var duringRegistration: (() -> Void)?
    public private(set) var canCorrelateShareReceipt = true
    public func addModuleListener(owns: @escaping (String) -> Bool, onSubmitted: @escaping (String, String) -> Void, onReceipt: @escaping (WechatReceipt) -> Void) -> UUID { let id = UUID(); observers[id] = Observer(owns: owns, submitted: onSubmitted, receipt: onReceipt); duringRegistration?(); return id }
    public func removeModuleListener(_ id: UUID) { observers.removeValue(forKey: id) }
    public func hasPendingRequest(requestID: String) -> Bool { pending.contains(requestID) || trusted.contains(requestID) }
    public func hasModuleOwner(requestID: String) -> Bool { observers.values.contains { $0.owns(requestID) } }
    public func canResume(requestID: String) -> Bool { trusted.contains(requestID) && !hasModuleOwner(requestID: requestID) }
    public func authorize(requestID: String) { precondition(Thread.isMainThread); starts.append(requestID); pending.insert(requestID) }
    public func shareImage(requestID: String, data: Data, scene: WechatScene, recipientID: String?, senderOpenID: String?) { starts.append(requestID); canCorrelateShareReceipt = false }
    public func shareWebPage(requestID: String, url: String, title: String, description: String, thumbnail: Data, scene: WechatScene) { starts.append(requestID); pending.insert(requestID) }
    public func openMerchantTransfer(requestID: String, merchantID: String, appID: String, packageValue: String) { starts.append(requestID); pending.insert(requestID) }
    public func cancel(requestID: String) { _ = cancelWithResult(requestID: requestID) }
    public func cancelWithResult(requestID: String) -> Bool { precondition(Thread.isMainThread); if cancellationSucceeds && cancellationHasPending { pending.remove(requestID); cancelled.append(requestID); emitSubmitted(requestID, "cancelled") }; return cancellationSucceeds && cancellationHasPending }
    func emitSubmitted(_ id: String, _ status: String) { for value in observers.values where value.owns(id) { value.submitted(id, status) } }
    func emit(_ receipt: WechatReceipt) { if let id = receipt.requestID ?? receipt.candidateRequestID { for value in observers.values where value.owns(id) { value.receipt(receipt) } } }
}
