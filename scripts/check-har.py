#!/usr/bin/env python3
"""Check a frozen HAR without extracting or trusting its archive paths."""
import json
from pathlib import PurePosixPath
import sys
import tarfile


def check_har(path, version):
    with tarfile.open(path) as archive:
        names = set()
        for member in archive.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir()):
                raise ValueError(f'Unsafe HAR member: {member.name}')
            if str(name) in names:
                raise ValueError(f'Duplicate HAR member: {member.name}')
            names.add(str(name))
        package = json.load(archive.extractfile('package/oh-package.json5'))
        if package['name'] != '@gycrosskit/wechat-native' or package['version'] != version:
            raise ValueError('HAR package identity differs')
        changelog = archive.extractfile('package/CHANGELOG.md').read().decode()
        if not any(line.lstrip('# ').split('（')[0].strip() == version for line in changelog.splitlines() if line.startswith('#')):
            raise ValueError('HAR changelog does not contain the exact version heading')
        exports = archive.extractfile('package/Index.ets').read().decode()
        for api in ('WechatClient', 'WechatModule', 'WechatPreferencesRequestStore'):
            if api not in exports:
                raise ValueError(f'HAR public export missing: {api}')
    return package


if __name__ == '__main__':
    check_har(sys.argv[1], sys.argv[2])
