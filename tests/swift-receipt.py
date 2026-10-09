"""用 SDK 最小替身执行生产分享与回包方法；不代替原厂 SDK ABI 或真机回跳。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / "iosApp/Sources/GycWechatNative/WechatClient.swift").read_text()
contracts = source[source.index("public enum WechatScene"):source.index("/// 宿主持有唯一实例")]
callback = source[source.index("    public func onResp("):source.index("    private func begin(")]
image_share = source[source.index("    public func shareImage("):source.index("    /// Main 分享无凭据")]
share = source[source.index("    private func share("):source.index("    private func send(")]
listener_fields = source[source.index("    private struct ModuleListener"):source.index("    private let registered:")]
listener_methods = source[source.index("    public func attach("):source.index("    /// Main 将 URL")]
output = root / "build/swift-receipt"
output.mkdir(parents=True, exist_ok=True)
(output / "main.swift").write_text("import Foundation\n" + contracts + """
class BaseResp { var errCode: Int32 = 0 }
class SendAuthResp: BaseResp { var state: String?; var code: String? }
class SendMessageToWXResp: BaseResp {}
class WXOpenBusinessViewResp: BaseResp { var businessType = ""; var extMsg: String? }
class BaseReq { var openID = "" }
class WXImageObject { var imageData = Data() }
class WXMediaMessage { var mediaObject: WXImageObject?; var thumbData: Data? }
class SendMessageToWXReq: BaseReq {
    var bText = true; var message: WXMediaMessage?; var scene: Int32 = -1; var toUserOpenId: String?
}
enum Scene: Int32 { case session = 0, timeline = 1, specified = 3 }
let WXSceneSession = Scene.session, WXSceneTimeline = Scene.timeline, WXSceneSpecifiedSession = Scene.specified
class ReceiptProbe {
    let session = WechatSession()
    var receipt: WechatReceipt?
    var requests: [SendMessageToWXReq] = []
    var statuses: [String] = []
    var accepted = true
    func deliver(_ value: WechatReceipt) { receipt = value }
    func begin(_ id: String, state: String? = nil, sharing: Bool = false) -> Bool {
        if let status = session.begin(id, state: state, sharing: sharing) { statuses.append(status); return false }
        return true
    }
    func reject(_ id: String, _ status: String) { _ = session.cancel(id); statuses.append(status) }
    static func thumbnail(_ data: Data) -> Data? { data }
    func send(_ request: BaseReq, id: String) {
        requests.append(request as! SendMessageToWXReq)
        session.dispatchedShare(id)
        if session.submitted(id, accepted: accepted) { statuses.append(accepted ? "requested" : "failed") }
    }
""" + callback + image_share + share + """
}
for value in [nil, "", " \\t\\n", "\\u{00a0}\\u{2003}", " code "] as [String?] {
    let probe = ReceiptProbe()
    precondition(probe.session.begin("auth", state: "state") == nil)
    let response = SendAuthResp(); response.state = "state"; response.code = value
    probe.onResp(response)
    let valid = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    precondition(probe.receipt?.errorCode == (valid ? 0 : -1))
    precondition(probe.receipt?.authorizationCode == (valid ? value : nil))
    precondition(probe.receipt?.requestID == "auth" && probe.receipt?.attribution == .verified)
    probe.receipt = nil
    probe.onResp(response)
    precondition(probe.receipt == nil)
}
print("Production Swift OAuth receipt rejects missing/blank code, preserves valid code and consumes once")
let target = ReceiptProbe()
target.shareImage(requestID: "target", data: Data([1]), scene: .session, recipientID: "receiver", senderOpenID: "sender")
precondition(target.statuses == ["requested"] && target.requests.count == 1)
let request = target.requests[0]
precondition(request.scene == 3 && request.toUserOpenId == "receiver" && request.openID == "sender")
precondition(!request.bText && request.message?.mediaObject?.imageData == Data([1]))
target.shareImage(requestID: "overlap", data: Data([1]), scene: .session)
precondition(target.statuses.last == "busy" && target.requests.count == 1)
target.onResp(SendMessageToWXResp())
precondition(target.receipt?.requestID == nil && target.receipt?.candidateRequestID == "target")
precondition(target.receipt?.attribution == .singlePending)
for scene in [WechatScene.session, .timeline] {
    let ordinary = ReceiptProbe()
    ordinary.shareImage(requestID: "ordinary", data: Data([1]), scene: scene, senderOpenID: "ignored")
    precondition(ordinary.statuses == ["requested"] && ordinary.requests.count == 1)
    precondition(ordinary.requests[0].scene == (scene == .session ? 0 : 1))
    precondition(ordinary.requests[0].toUserOpenId == nil && ordinary.requests[0].openID.isEmpty)
}
for (recipient, sender, scene, status) in [
    ("", "sender", WechatScene.session, "invalid_content"),
    (" \\t", "sender", .session, "invalid_content"),
    ("receiver", "sender", .timeline, "invalid_content"),
    ("receiver", nil, .session, "unsupported"),
    ("receiver", " \\n", .session, "unsupported"),
] as [(String, String?, WechatScene, String)] {
    let invalid = ReceiptProbe()
    invalid.shareImage(requestID: "invalid", data: Data([1]), scene: scene, recipientID: recipient, senderOpenID: sender)
    precondition(invalid.statuses == [status] && invalid.requests.isEmpty)
    invalid.shareImage(requestID: "retry", data: Data([1]), scene: .session)
    precondition(invalid.statuses.last == "requested")
}
for bytes in [Data(), Data(repeating: 0, count: 25 * 1024 * 1024 + 1)] {
    let invalid = ReceiptProbe()
    invalid.shareImage(requestID: "invalid", data: bytes, scene: .session, recipientID: "receiver", senderOpenID: "sender")
    precondition(invalid.statuses == ["invalid_content"] && invalid.requests.isEmpty)
}
let refused = ReceiptProbe(); refused.accepted = false
refused.shareImage(requestID: "refused", data: Data([1]), scene: .session, recipientID: "receiver", senderOpenID: "sender")
precondition(refused.statuses == ["failed"])
precondition(refused.session.begin("retry", sharing: true) == nil)
let cancelled = ReceiptProbe()
cancelled.shareImage(requestID: "cancel", data: Data([1]), scene: .session, recipientID: "receiver", senderOpenID: "sender")
precondition(cancelled.session.cancel("cancel"))
cancelled.onResp(SendMessageToWXResp())
precondition(cancelled.receipt == nil && cancelled.session.begin("late", sharing: true) == "unsupported")
print("Production Swift targeted/ordinary image requests, trusted identities, SDK refusal and late-receipt isolation passed")
precondition(wechatText(String(repeating: "e\\u{0301}", count: 300), characters: 256, bytes: 512) == String(repeating: "e\\u{0301}", count: 128))
precondition(wechatText("a😀", characters: 2, bytes: 512) == "a")
print("Production Swift UTF-16 and UTF-8 text limits match Kotlin and OHOS")
""")
# 直接编译生产字段/方法，不重写回放算法；SDK只在既有分享探针中替身。
with (output / "main.swift").open("a") as fixture:
    fixture.write("class ListenerProbe { let session = WechatSession(); let submitted: (String, String) -> Void = { _, _ in }\n" + listener_fields + listener_methods + """
    func submit(_ id: String) { notifySubmitted(id, "requested") }
    func seed(_ id: String) { deliver(WechatReceipt(requestID: id, kind: .authorization, errorCode: 0, authorizationCode: nil, pageResult: nil)) }
}
for mode in ["detach", "replace"] {
    let replay = ListenerProbe(); replay.seed("a"); replay.seed("b"); replay.seed("c")
    var old = [String](), next = [String]()
    replay.attach { value in
        old.append(value.requestID!)
        replay.detach()
        if mode == "replace" { replay.attach { next.append($0.requestID!) } }
    }
    precondition(old == ["a"])
    if mode == "detach" { replay.attach { next.append($0.requestID!) } }
    precondition(next == ["b", "c"])
    replay.detach(); replay.attach { _ in preconditionFailure("receipt replayed twice") }
}
print("Production Swift replay detachment/replacement preserves remaining receipts exactly once")
let modules = ListenerProbe()
modules.seed("buffered")
var owned = Set(["buffered", "live"]), other = Set(["other"])
var delivered = [String](), submittedIDs = [String](), otherDelivered = [String]()
let registration = modules.addModuleListener(owns: { owned.contains($0) }, onSubmitted: { id, _ in submittedIDs.append(id) }, onReceipt: {
    delivered.append($0.requestID!)
    owned.remove($0.requestID!)
})
let next = modules.addModuleListener(owns: { other.contains($0) }, onSubmitted: { _, _ in }, onReceipt: { otherDelivered.append($0.requestID!) })
precondition(delivered == ["buffered"] && otherDelivered.isEmpty)
precondition(modules.hasModuleOwner(requestID: "live") && !modules.canResume(requestID: "live"))
modules.submit("live"); modules.seed("live")
precondition(submittedIDs == ["live"] && delivered == ["buffered", "live"] && otherDelivered.isEmpty)
modules.removeModuleListener(registration)
precondition(!modules.canResume(requestID: "live"))
modules.seed("live")
precondition(delivered.count == 2)
modules.removeModuleListener(next)
print("Production Swift filtered module observers: trusted buffer once, ownership, submit callback, removal and renderer isolation passed")
""")
subprocess.run(["swiftc", str(root / "iosApp/Sources/GycWechatNative/WechatSession.swift"),
                str(output / "main.swift"), "-o", str(output / "check")], check=True)
subprocess.run([str(output / "check")], check=True)
