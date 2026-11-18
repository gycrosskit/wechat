#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Pass an immutable released Maven version}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid release version" >&2; exit 1; }
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
# 从不可变版本 Tag 取得提交和 tree，沿用 JitPack 的回执与归档校验。
repo_root="$PWD"
git init -q "$output/tag"
git -C "$output/tag" fetch -q --no-tags --depth=1 https://github.com/gycrosskit/wechat.git "refs/tags/$VERSION"
git -C "$output/tag" checkout -q --detach FETCH_HEAD
commit="$(git -C "$output/tag" rev-parse --verify HEAD)"
(cd "$output/tag" && bash "$repo_root/jitpack-install.sh" wechat "$output/maven")
python3 scripts/check-maven.py "$output/maven" com.github.gycrosskit.wechat "$VERSION" wechat-core,wechat-kuikly ios_arm64,ios_x64,ios_simulator_arm64,ohos_arm64
# 消费方只使用 JitPack；归档校验不会安装到 MavenLocal 或替代远程解析。

# 预期 inventory 来自通过冻结 SHA 的归档，不从 JitPack 自报 inventory 反推。
publications="$(python3 - "$output/maven" <<'PYTHON'
import sys
from pathlib import Path
print(','.join(sorted(path.parent.parent.name for path in Path(sys.argv[1]).rglob('*.module'))))
PYTHON
)"
python3 scripts/check-public-maven.py --repo wechat --version "$VERSION" --commit "$commit" --expected-publications "$publications" --output-dir "${CI_DIAGNOSTICS_DIR:-ci-diagnostics}/public"
