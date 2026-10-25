"""Offline HAR identity and public-consumer fixtures; no SDK or network calls."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('check_har', ROOT / 'scripts/check-har.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
VERSION = '0.1.8-rc.1'
COMMIT = 'a' * 40


def har(path, version=VERSION, extra=None):
    entries = {
        'package/oh-package.json5': json.dumps({'name': '@gycrosskit/wechat-native', 'version': version}),
        'package/CHANGELOG.md': '# ' + version + '（2026-10-18）\n',
        'package/Index.ets': 'export { WechatClient, WechatModule, WechatPreferencesRequestStore };',
    }
    if extra:
        entries.update(extra)
    with tarfile.open(path, 'w:gz') as archive:
        for name, content in entries.items():
            data = content.encode()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))


class HarReleaseTest(unittest.TestCase):
    def test_archive_identity_and_untrusted_members(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'release.har'
            har(path)
            self.assertEqual(CHECK.check_har(path, VERSION)['version'], VERSION)
            for extra in ({'../escape': ''}, {'package/CHANGELOG.md': '# ' + VERSION + '0\n'}, {'package/Index.ets': ''}):
                har(path, extra=extra)
                with self.assertRaises(ValueError):
                    CHECK.check_har(path, VERSION)
            har(path, version='0.1.7')
            with self.assertRaises(ValueError):
                CHECK.check_har(path, VERSION)

    def public_consumer(self, failure=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            for name in ('verify-public-har.sh', 'check-har.py'):
                shutil.copyfile(ROOT / 'scripts' / name, root / 'scripts' / name)
            shutil.copytree(ROOT / 'verification/ohos', root / 'verification/ohos')
            fixture = root / 'fixture.har'
            har(fixture, version='0.1.7' if failure == 'version' else VERSION)
            checksum = hashlib.sha256(fixture.read_bytes()).hexdigest()
            (root / 'har-release-checksums.txt').write_text('' if failure == 'missing' else f'har-{VERSION} {checksum} {COMMIT}\n')
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            commands = {
                'git': '''#!/usr/bin/env python3
import os, sys
commit = 'a' * 40
if sys.argv[1] == 'rev-parse': print(commit)
elif sys.argv[1] == 'ls-remote': print(('b' * 40 if os.environ['FAILURE'] == 'tag' else commit) + '\\trefs/tags/har-0.1.8-rc.1')
elif sys.argv[1] == 'diff': sys.exit(1 if os.environ['FAILURE'] == 'source' else 0)
else: sys.exit(2)
''',
                'curl': '''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
target = Path(sys.argv[sys.argv.index('-o') + 1])
if sys.argv[-1].endswith('/WechatNative.har'): shutil.copyfile(os.environ['FIXTURE'], target)
else: target.write_text(('b' if os.environ['FAILURE'] == 'receipt' else 'a') * 40 + '\\n')
''',
                'ohpm': '''#!/usr/bin/env python3
import json
from pathlib import Path
assert json.loads(Path('consumer/oh-package.json5').read_text())['dependencies']['@gycrosskit/wechat-native'] == 'file:../../WechatNative.har'
assert Path('../WechatNative.har').is_file()
assert not Path('ohos/wechat-native').exists()
''',
                'hvigorw': '#!/usr/bin/env bash\n[[ "$*" == "--mode module -p module=Consumer@default -p product=default assembleHar --no-daemon" ]]\n',
            }
            for name, content in commands.items():
                executable = bin_dir / name
                executable.write_text(content)
                executable.chmod(0o755)
            result = subprocess.run(['bash', 'scripts/verify-public-har.sh'], cwd=root, text=True, capture_output=True, env={
                **os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                'HARMONY_CLT_HOME': str(root / 'clt'), 'SOURCE_COMMIT': COMMIT,
                'VERIFY_TAG': 'har-' + VERSION, 'VERIFY_HAR_SHA': '0' * 64 if failure == 'sha' else checksum,
                'FIXTURE': str(fixture), 'FAILURE': failure,
            })
            proof = root / 'build/public-har/proof.json'
            if failure:
                self.assertNotEqual(result.returncode, 0, failure)
                self.assertFalse(proof.exists(), failure)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(proof.read_text())['sha256'], checksum)

    def test_clean_public_har_consumer(self):
        self.public_consumer()

    def test_identity_failures_do_not_emit_success_proof(self):
        for failure in ('sha', 'missing', 'tag', 'source', 'receipt', 'version'):
            with self.subTest(failure=failure):
                self.public_consumer(failure)



if __name__ == '__main__':
    unittest.main()
