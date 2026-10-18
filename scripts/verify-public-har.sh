#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERIFY_TAG:?Pass an immutable HAR release tag}"
: "${VERIFY_HAR_SHA:?Pass the frozen HAR SHA-256}"
: "${SOURCE_COMMIT:?Pass the full released checkout commit}"
: "${HARMONY_CLT_HOME:?Remote agent must provide the installed HarmonyOS CLT}"
[[ "$VERIFY_TAG" =~ ^har-([0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?)$ ]] || { echo 'Invalid HAR tag' >&2; exit 1; }
[[ "$VERIFY_HAR_SHA" =~ ^[0-9a-f]{64}$ && "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid frozen identity' >&2; exit 1; }
test "$(git rev-parse HEAD)" = "$SOURCE_COMMIT"
frozen=$(awk -v tag="$VERIFY_TAG" '$1 == tag {print $2, $3}' har-release-checksums.txt)
[[ "$frozen" =~ ^([0-9a-f]{64})[[:blank:]]([0-9a-f]{40})$ ]] || { echo 'Expected one frozen HAR hash and build commit' >&2; exit 1; }
frozen_sha="${BASH_REMATCH[1]}"
build_commit="${BASH_REMATCH[2]}"
test "$frozen_sha" = "$VERIFY_HAR_SHA"
refs=$(git ls-remote --tags https://github.com/gycrosskit/wechat.git "refs/tags/$VERIFY_TAG" "refs/tags/$VERIFY_TAG^{}")
tag_commit=$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ {peeled=$1} {plain=$1} END {print peeled ? peeled : plain}')
test "$tag_commit" = "$SOURCE_COMMIT"
# The checksum-only commit may follow packaging; the published module must remain byte-identical.
git diff --exit-code "$build_commit" HEAD -- ohos/wechat-native
export NODE_HOME="$HARMONY_CLT_HOME/tool/node"
export DEVECO_SDK_HOME="$HARMONY_CLT_HOME/sdk"
export PATH="$NODE_HOME/bin:$HARMONY_CLT_HOME/ohpm/bin:$HARMONY_CLT_HOME/bin:$PATH"
export TYPESCRIPT_PATH="$HARMONY_CLT_HOME/ohpm/node_modules/typescript"
output="$PWD/build/public-har"
test ! -e "$output"
mkdir -p "$output"
base="https://github.com/gycrosskit/wechat/releases/download/$VERIFY_TAG"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 -o "$output/WechatNative.har" "$base/WechatNative.har"
curl --fail --location --retry 2 --connect-timeout 15 --max-time 90 -o "$output/source-commit.txt" "$base/source-commit.txt"
printf '%s  %s\n' "$VERIFY_HAR_SHA" "$output/WechatNative.har" | shasum -a 256 --check
test "$(cat "$output/source-commit.txt")" = "$build_commit"
version="${VERIFY_TAG#har-}"
python3 scripts/check-har.py "$output/WechatNative.har" "$version"
python3 - "$output" <<'PY'
import json
from pathlib import Path
import shutil
import sys
output = Path(sys.argv[1])
shutil.copytree('verification/ohos', output / 'project', ignore=shutil.ignore_patterns('build', 'oh_modules', '.hvigor', 'oh-package-lock.json5'))
manifest = output / 'project/consumer/oh-package.json5'
package = json.loads(manifest.read_text())
package['dependencies']['@gycrosskit/wechat-native'] = 'file:../../WechatNative.har'
manifest.write_text(json.dumps(package, indent=2) + '\n')
PY
(
  cd "$output/project"
  ohpm install --all
  hvigorw --mode module -p module=Consumer@default -p product=default assembleHar --no-daemon
)
python3 - "$output" "$VERIFY_TAG" "$VERIFY_HAR_SHA" "$SOURCE_COMMIT" "$build_commit" <<'PY'
import json
from pathlib import Path
import sys
output = Path(sys.argv[1])
proof = dict(zip(('tag', 'sha256', 'releaseCommit', 'buildCommit'), sys.argv[2:]))
proof.update(package='@gycrosskit/wechat-native', version=sys.argv[2][4:], consumer='Consumer@default', task='assembleHar', result='passed', registryInstall=False, deviceBusiness=False)
(output / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
PY
