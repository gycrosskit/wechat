"""Execute the production receiver against controlled native/render boundaries; not SDK business proof."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
fixtures = Path(__file__).resolve().parent
output = root / "build/swift-kuikly"
output.mkdir(parents=True, exist_ok=True)
subprocess.run(["swiftc", "-emit-module", "-emit-library", "-module-name", "OpenKuiklyIOSRender",
    str(fixtures / "MocksRender.swift"), "-o", str(output / "libOpenKuiklyIOSRender.dylib"),
    "-emit-module-path", str(output / "OpenKuiklyIOSRender.swiftmodule")], check=True)
subprocess.run(["swiftc", "-I", str(output), "-L", str(output), "-lOpenKuiklyIOSRender", "-Xlinker", "-rpath", "-Xlinker", str(output),
    str(fixtures / "MocksNative.swift"), str(root / "iosApp/Sources/GycWechatKuikly/WechatModule.swift"),
    str(fixtures / "main.swift"), "-o", str(output / "check")], check=True)
subprocess.run([str(output / "check")], check=True)
