import Foundation
public enum WechatScene { case session, timeline }
public enum WechatKind { case authorization, share, merchantTransfer }
public enum WechatAttribution { case verified, singlePending, unattributed }
public struct WechatReceipt {
    public let requestID: String?; public let candidateRequestID: String?; public let kind: WechatKind; public let errorCode: Int32
    public let authorizationCode: String? = nil; public let pageResult: String? = nil; public let attribution: WechatAttribution
}
public final class WechatClient {
    struct Observer { let owns: (String) -> Bool; let submitted: (String, String) -> Void; let receipt: (WechatReceipt) -> Void }
    var observers = [UUID: Observer](); var starts = [String](); var cancelled = [String](); var cancellationSucceeds = true
    var trusted = Set<String>(); var duringRegistration: (() -> Void)?
    public func addModuleListener(owns: @escaping (String) -> Bool, onSubmitted: @escaping (String, String) -> Void, onReceipt: @escaping (WechatReceipt) -> Void) -> UUID { let id = UUID(); observers[id] = Observer(owns: owns, submitted: onSubmitted, receipt: onReceipt); duringRegistration?(); return id }
    public func removeModuleListener(_ id: UUID) { observers.removeValue(forKey: id) }
    public func hasModuleOwner(requestID: String) -> Bool { observers.values.contains { $0.owns(requestID) } }
    public func canResume(requestID: String) -> Bool { trusted.contains(requestID) && !hasModuleOwner(requestID: requestID) }
    public func authorize(requestID: String) { precondition(Thread.isMainThread); starts.append(requestID) }
    public func shareImage(requestID: String, data: Data, scene: WechatScene, recipientID: String?, senderOpenID: String?) { starts.append(requestID) }
    public func shareWebPage(requestID: String, url: String, title: String, description: String, thumbnail: Data, scene: WechatScene) { starts.append(requestID) }
    public func openMerchantTransfer(requestID: String, merchantID: String, appID: String, packageValue: String) { starts.append(requestID) }
    public func cancel(requestID: String) { _ = cancelWithResult(requestID: requestID) }
    public func cancelWithResult(requestID: String) -> Bool { precondition(Thread.isMainThread); if cancellationSucceeds { cancelled.append(requestID); emitSubmitted(requestID, "cancelled") }; return cancellationSucceeds }
    func emitSubmitted(_ id: String, _ status: String) { for value in observers.values where value.owns(id) { value.submitted(id, status) } }
    func emit(_ receipt: WechatReceipt) { if let id = receipt.requestID ?? receipt.candidateRequestID { for value in observers.values where value.owns(id) { value.receipt(receipt) } } }
}
