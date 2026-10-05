"""用 SDK 最小回包替身执行生产 onResp 方法；不代替原厂 SDK ABI 或真机回跳。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / "iosApp/Sources/GycWechatNative/WechatClient.swift").read_text()
contracts = source[source.index("public enum WechatScene"):source.index("/// 宿主持有唯一实例")]
callback = source[source.index("    public func onResp("):source.index("    private func begin(")]
output = root / "build/swift-receipt"
output.mkdir(parents=True, exist_ok=True)
(output / "main.swift").write_text("import Foundation\n" + contracts + """
class BaseResp { var errCode: Int32 = 0 }
class SendAuthResp: BaseResp { var state: String?; var code: String? }
class SendMessageToWXResp: BaseResp {}
class WXOpenBusinessViewResp: BaseResp { var businessType = ""; var extMsg: String? }
class ReceiptProbe {
    let session = WechatSession()
    var receipt: WechatReceipt?
    func deliver(_ value: WechatReceipt) { receipt = value }
""" + callback + """
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
""")
subprocess.run(["swiftc", str(root / "iosApp/Sources/GycWechatNative/WechatSession.swift"),
                str(output / "main.swift"), "-o", str(output / "check")], check=True)
subprocess.run([str(output / "check")], check=True)
