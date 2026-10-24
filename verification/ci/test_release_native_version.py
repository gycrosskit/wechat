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
    def test_renderer_probe_follows_module_constraint_and_preserves_remote_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binary = folder / 'bin'
            binary.mkdir()
            pod = binary / 'pod'
            pod.write_text('''#!/bin/sh
ruby -rjson -e '
def install!(*); end
def platform(*); end
def use_frameworks!(*); end
def target(*); yield; end
def pod(*args, **options); (@pods ||= []) << [args, options]; end
load "Podfile"
File.write(ENV.fetch("GYC_DEPENDENCY_RECEIPT"), JSON.generate(@pods))
'
exit 75
''')
            pod.chmod(0o755)
            for label, arguments in [('renderer', []), ('local', ['GycWechatNative/Kuikly']),
                                     ('remote', ['GycWechatNative/Kuikly', 'wechat', 'native-1.0.0'])]:
                with self.subTest(label=label):
                    receipt = folder / (label + '.json')
                    result = subprocess.run(['bash', str(ROOT / 'scripts/ci-build-kuikly-render.sh'),
                        str(folder / label), *arguments], cwd=ROOT,
                        env={**os.environ, 'PATH': str(binary) + os.pathsep + os.environ['PATH'],
                             'GYC_DEPENDENCY_RECEIPT': str(receipt)}, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 75, result.stderr)
                    dependencies = json.loads(receipt.read_text())
                    if label == 'renderer':
                        self.assertEqual(dependencies, [[['OpenKuiklyIOSRender', '2.29.1'], {}]])
                    else:
                        self.assertEqual(len(dependencies), 1, 'Renderer version must come from the Module podspec')
                        self.assertEqual(dependencies[0][0], ['GycWechatNative/Kuikly'])
                        options = dependencies[0][1]
                        if label == 'local': self.assertEqual(options, {'path': str(ROOT)})
                        else: self.assertEqual(options, {'git': 'https://github.com/gycrosskit/wechat.git', 'tag': 'native-1.0.0'})

    def test_current_module_pins_the_same_renderer_as_kotlin(self):
        result = subprocess.run(['pod', 'ipc', 'spec', 'GycWechatNative.podspec'], cwd=ROOT,
            text=True, capture_output=True, check=True)
        kuikly = next(x for x in json.loads(result.stdout)['subspecs'] if x['name'] == 'Kuikly')
        self.assertEqual(kuikly['dependencies']['OpenKuiklyIOSRender'], ['2.29.1'])
        kotlin = (ROOT / 'gradle/libs.versions.toml').read_text()
        self.assertIn('kuikly = "2.29.1-2.0.21-ohos"', kotlin)

    def test_maven_receiver_uses_declared_native_tag(self):
        workflow = (ROOT / '.github/workflows/release-validation.yml').read_text()
        command = re.search(r'^\s+(native_tag=.+)$', workflow, re.M)
        self.assertIsNotNone(command)
        self.assertIn('GycWechatNative/Kuikly wechat "$native_tag"', workflow)
        with tempfile.TemporaryDirectory() as directory:
            spec = (ROOT / 'GycWechatNative.podspec').read_text()
            spec = re.sub(r"s.version = '[^']+'", "s.version = '7.8.9'", spec)
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
