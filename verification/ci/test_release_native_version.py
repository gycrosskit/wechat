"""离线核对 Native 发布版本传递，不解析或构建远程依赖。"""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseNativeVersionTest(unittest.TestCase):
    def test_maven_receiver_uses_declared_native_tag(self):
        workflow = (ROOT / '.github/workflows/release-validation.yml').read_text()
        command = re.search(r'^\s+(native_tag=.+)$', workflow, re.M)
        self.assertIsNotNone(command)
        self.assertIn('GycWechatNative/Kuikly wechat "$native_tag"', workflow)
        with tempfile.TemporaryDirectory() as directory:
            spec = (ROOT / 'GycWechatNative.podspec').read_text()
            spec = re.sub(r":tag => '[^']+'", ":tag => 'native-7.8.9'", spec)
            (Path(directory) / 'GycWechatNative.podspec').write_text(spec)
            result = subprocess.run(
                ['bash', '-ec', command.group(1) + '\nprintf "%s" "$native_tag"'],
                cwd=directory, env={**os.environ, 'VERSION': '2.3.4'},
                text=True, capture_output=True, check=True,
            )
            self.assertEqual(result.stdout, 'native-7.8.9')

    def manifest(self, version):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ)
            env.pop('VERSION', None)
            if version is not None:
                env['VERSION'] = version
            env['CLANG_MODULE_CACHE_PATH'] = directory + '/modules'
            env['SWIFT_MODULECACHE_PATH'] = directory + '/modules'
            return subprocess.run(
                ['swift', 'package', '--package-path', str(ROOT / 'verification/swift-consumer'),
                 '--scratch-path', directory + '/build', 'dump-package'],
                env=env, text=True, capture_output=True,
            )

    def test_spm_uses_each_requested_native_release(self):
        for tag in ['native-0.1.8', 'native-7.8.9']:
            with self.subTest(tag=tag):
                result = self.manifest(tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                dependency = json.loads(result.stdout)['dependencies'][0]['sourceControl'][0]
                self.assertEqual(dependency['requirement']['revision'], [tag])

    def test_spm_rejects_missing_or_non_native_release(self):
        for version in [None, '0.1.9', 'native-main']:
            with self.subTest(version=version):
                result = self.manifest(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('VERSION must be an immutable native release tag', result.stderr)


if __name__ == '__main__':
    unittest.main()
