#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HARMONY_CLT_HOME:?Remote agent must provide the installed HarmonyOS CLT}"
export NODE_HOME="$HARMONY_CLT_HOME/tool/node"
export DEVECO_SDK_HOME="$HARMONY_CLT_HOME/sdk"
export PATH="$NODE_HOME/bin:$HARMONY_CLT_HOME/ohpm/bin:$HARMONY_CLT_HOME/bin:$PATH"
test ! -e build/release-candidate
export TYPESCRIPT_PATH="$HARMONY_CLT_HOME/ohpm/node_modules/typescript"
node tests/wechat.cjs
node tests/preferences-store.cjs
(
  cd ohos
  ohpm install --all
  hvigorw --mode module -p module=WechatNative@default -p product=default assembleHar --no-daemon
)
mkdir -p build/release-candidate
python3 - <<'PY'
import json
import shutil
import tarfile
from pathlib import Path
packages = list(Path('ohos/wechat-native/build/default/outputs/default').glob('*.har'))
assert len(packages) == 1, f'Expected one HAR, got {len(packages)}'
version = json.loads(Path('ohos/wechat-native/oh-package.json5').read_text())['version']
with tarfile.open(packages[0]) as archive:
    package = json.load(archive.extractfile('package/oh-package.json5'))
    assert package['name'] == '@gycrosskit/wechat-native' and package['version'] == version
    assert version in archive.extractfile('package/CHANGELOG.md').read().decode()
shutil.copyfile(packages[0], 'build/release-candidate/WechatNative.har')
PY
ohpm prepublish build/release-candidate/WechatNative.har
shasum -a 256 build/release-candidate/WechatNative.har | awk '{print $1}' > build/release-candidate/har.sha256
git rev-parse HEAD > build/release-candidate/source-commit.txt
