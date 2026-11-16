#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Pass the immutable candidate version}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid version" >&2; exit 2; }
export VERSION
test ! -e build/release-candidate
test ! -e "build/maven/com/github/gycrosskit/wechat/wechat-core/$VERSION"
bash gradlew --init-script "$PWD/scripts/ci-repositories.gradle" publishAllPublicationsToStagingRepository --no-daemon --max-workers=1 --stacktrace --info
python3 scripts/jitpack-metadata.py build/maven
python3 scripts/check-maven.py build/maven com.github.gycrosskit.wechat "$VERSION" wechat-core,wechat-kuikly ios_arm64,ios_x64,ios_simulator_arm64,ohos_arm64
mkdir -p build/release-candidate
python3 release-pack.py build/maven build/release-candidate/wechat-maven.tar.gz "$VERSION"
shasum -a 256 build/release-candidate/wechat-maven.tar.gz | awk '{print $1}' > build/release-candidate/maven.sha256
git rev-parse HEAD > build/release-candidate/source-commit.txt
printf '%s\n' "$VERSION" > build/release-candidate/maven-version.txt
