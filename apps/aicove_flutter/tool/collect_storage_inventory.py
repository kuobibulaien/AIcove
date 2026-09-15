#!/usr/bin/env python3
"""Fetch content-free Android storage metadata through the local diagnostic service."""
import argparse
import json
import os
import re
import urllib.request
from pathlib import Path

from collect_diagnostics import Adb, choose_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    token = os.environ.get('AICOVE_DIAGNOSTIC_TOKEN', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
        parser.error('Set AICOVE_DIAGNOSTIC_TOKEN to the existing device credential')
    device = Adb(choose_device(args.device), 'com.example.aicove_flutter')
    forwarded = device.run('forward', 'tcp:0', 'tcp:48631')
    if not re.fullmatch(r'\d{1,5}', forwarded):
        raise RuntimeError('Invalid ADB forwarded port')
    try:
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *unused):
                return None

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        request = urllib.request.Request(
            f'http://127.0.0.1:{forwarded}/v1/storage',
            headers={'Authorization': f'Bearer {token}'})
        with opener.open(request, timeout=90) as response:
            data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise RuntimeError('Inventory response exceeds size limit')
        report = json.loads(data)
        if report.get('format') != 'aicove-storage-inventory-v1':
            raise RuntimeError('Unexpected inventory format')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as out:
            json.dump(report, out, ensure_ascii=False, indent=2)
        print(args.output.resolve())
        print(json.dumps({key: report[key] for key in ['totalBytes', 'fileCount', 'buckets', 'coverage']}, ensure_ascii=False))
    finally:
        device.run('forward', '--remove', f'tcp:{forwarded}')


if __name__ == '__main__':
    main()
