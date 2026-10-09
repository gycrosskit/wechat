"""Typecheck the public receiver API from a real Simulator Pod build; no vendor business call."""
from pathlib import Path
import platform
import subprocess
import sys

products = Path(sys.argv[1]).resolve()
sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
command = ["xcrun", "swiftc", "-typecheck", "-target", platform.machine() + "-apple-ios15.0-simulator", "-sdk", sdk, "-F", str(products)]
command += ["-F", str(products / "XCFrameworkIntermediates/WechatOpenSDK-XCFramework")]
command += [str(Path(__file__).with_name("PublicAPI.swift"))]
subprocess.run(command, check=True)
print("Independent real Pod receiver public API import/typecheck passed")
