"""执行真实 Client/Session URL 入口；仅 SDK 与图片转换为替身，不重写状态机。"""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / "build/swift-callback"
output.mkdir(parents=True, exist_ok=True)
path = root / "iosApp/Sources/GycWechatNative/WechatClient.swift"
source = path.read_text()
# 保留完整 Client；只排除无关 ImageIO/UIKit 缩略图转换和厂商 import。
prefix, thumbnail = source.split("    private static func thumbnail(_ data: Data) -> Data? {", 1)
assert thumbnail.endswith("\n    }\n}\n")
prefix = prefix.replace("import ImageIO\n", "").replace("import UIKit\n", "").replace("import WechatOpenSDK\n", "")
client = prefix + "    private static func thumbnail(_ data: Data) -> Data? { data }\n}\n"
(output / "WechatClient.swift").write_text(client)
(output / "source-proof.json").write_text(json.dumps({
    "source": str(path.relative_to(root)), "sha256": hashlib.sha256(source.encode()).hexdigest(),
    "compiled_prefix_sha256": hashlib.sha256(prefix.encode()).hexdigest(),
    "session_sha256": hashlib.sha256((root / "iosApp/Sources/GycWechatNative/WechatSession.swift").read_bytes()).hexdigest(),
    "fixture_sha256": hashlib.sha256((root / "tests/swift-callback/main.swift").read_bytes()).hexdigest(),
    "excluded": ["UIKit/ImageIO thumbnail conversion", "WechatOpenSDK import"],
}, indent=2) + "\n")
subprocess.run(["swiftc", str(output / "WechatClient.swift"),
                str(root / "iosApp/Sources/GycWechatNative/WechatSession.swift"),
                str(root / "tests/swift-callback/main.swift"), "-o", str(output / "check")], check=True)
subprocess.run([str(output / "check")], check=True)
