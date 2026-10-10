#!/usr/bin/env python3
"""Build a sanitized public AIcove release and optionally publish it.

Stages (each resumes from its done marker in the work directory):
  prepare  git archive -> drop private fixtures -> sanitize -> privacy scan
           -> sync into a fresh clone of the public repository -> hygiene test
  test     full Flutter suite on a copy of the sanitized source (runs in
           parallel with build; skip with --skip-tests)
  build    Android APK + macOS app + unsigned iOS IPA from a sanitized copy,
           strip (and re-sign the Mac app), privacy-scan all packages,
           write SHA256SUMS. The Windows ZIP is built afterwards by
           .github/workflows/windows-release.yml in the public repository.
  publish  only with --publish: commit and push the public repository,
           create the GitHub release, download it again and verify hashes

Typical use (from any directory):
  python3 apps/aicove_flutter/tool/publish_release.py 0.1.0-test.5
  # write release notes (the "new and improved" part only), then:
  python3 apps/aicove_flutter/tool/publish_release.py 0.1.0-test.5 \
      --notes /private/tmp/aicove-release-0.1.0-test.5/notes.md --publish

Private terms to scrub besides the home directory name and git email go in
~/.config/aicove/release_private.json: {"terms": [...], "device_serials": [...]}.
Serials of currently attached adb devices are added automatically.
"""
import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
import zipfile
from collections import Counter
from pathlib import Path

PUBLIC_REPO = 'kuobibulaien/AIcove'
PUBLIC_USER = 'kuobibulaien'
PUBLIC_EMAIL = 'kuobibulaien@users.noreply.github.com'
# Split so that sanitizing this very file leaves it unchanged.
USERS_DIR = '/' + 'Users' + '/'
REPO_ROOT = Path(__file__).resolve().parents[3]
APP_REL = 'apps/aicove_flutter'
PRIVATE_FIXTURE_DIRS = (
    f'{APP_REL}/test/fixtures/preset_runtime',
    f'{APP_REL}/test/fixtures/preset_tags',
    'test/fixtures/preset_tags',
)
PRIVATE_FIXTURE_REF = re.compile(r'fixtures/preset_runtime|fixtures/preset_tags|kemini_fixture')
MACHO_MAGIC = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
               b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def log(message):
    print(f'[{datetime.datetime.now():%H:%M:%S}] {message}', flush=True)


def run(cmd, cwd=None, log_file=None, **kwargs):
    if log_file:
        with open(log_file, 'w') as out:
            return subprocess.run(cmd, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=True, **kwargs)
    return subprocess.run(cmd, cwd=cwd, check=True, **kwargs)


def output(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class Private:
    """Everything that must not leave this machine, plus how to rewrite it."""

    def __init__(self):
        home = Path.home()
        self.username = home.name
        self.home = str(home)
        config = home / '.config/aicove/release_private.json'
        data = json.loads(config.read_text()) if config.exists() else {}
        self.terms = set(data.get('terms', []))
        email = subprocess.run(['git', 'config', 'user.email'], cwd=REPO_ROOT,
                               capture_output=True, text=True).stdout.strip()
        if email:
            self.terms.add(email)
        self.serials = set(data.get('device_serials', []))
        try:
            devices = output(['adb', 'devices'])
            self.serials.update(line.split()[0] for line in devices.splitlines()[1:] if line.strip())
        except (OSError, subprocess.CalledProcessError):
            pass

    def sanitize(self, text):
        text = text.replace(str(REPO_ROOT), '/path/to/aicove')
        text = text.replace(f'{self.home}/dev-sdks', '/path/to')
        text = text.replace(self.home, f'/home/{PUBLIC_USER}')
        text = text.replace(self.username, PUBLIC_USER)
        text = re.sub(re.escape(USERS_DIR) + r'[^/\s"\'`<>]+', '/path/to/home', text)
        text = text.replace(USERS_DIR, '/home/')
        for serial in self.serials:
            text = text.replace(serial, '<设备号>')
        for term in self.terms:
            text = text.replace(term, PUBLIC_EMAIL if '@' in term else '<已脱敏>')
        return text

    def hits(self, data, include_users_dir=True):
        # USERS_DIR is matched case-sensitively: "/api/v1/admin/users/" is fine.
        lowered = data.lower()
        needles = [self.username, *self.terms, *self.serials]
        found = [n for n in needles if n.lower().encode() in lowered]
        if include_users_dir and USERS_DIR.encode() in data:
            found.append(USERS_DIR)
        return found


def scan_tree(root, private):
    hits = {}
    for path in root.rglob('*'):
        if path.is_file() and not path.is_symlink() and '.git' not in path.relative_to(root).parts:
            found = private.hits(path.read_bytes())
            if found:
                hits[str(path.relative_to(root))] = found
    return hits


def strip_macho(bundle):
    """Strip debug and local symbols from every Mach-O file in an app bundle."""
    for path in bundle.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        before = subprocess.check_output(['nm', '-gjU', str(path)], stderr=subprocess.DEVNULL)
        run(['strip', '-S', '-x', str(path)], capture_output=True)
        if subprocess.check_output(['nm', '-gjU', str(path)], stderr=subprocess.DEVNULL) != before:
            sys.exit(f'build: stripping changed exported symbols of {path.name}')


class Release:
    def __init__(self, args):
        self.args = args
        self.version = args.version
        self.work = Path(args.workdir or f'/private/tmp/aicove-release-{self.version}')
        self.export = self.work / 'export'
        self.publish_dir = self.work / 'publish'
        self.build_src = self.work / 'build-src'
        self.test_src = self.work / 'test-src'
        self.assets = self.work / 'assets'
        self.apk_name = f'AIcove-{self.version}-android.apk'
        self.zip_name = f'AIcove-{self.version}-macos-arm64.zip'
        self.ipa_name = f'AIcove-{self.version}-ios-unsigned.ipa'
        self.private = Private()

    def done(self, stage):
        return (self.work / f'.done-{stage}').exists()

    def mark(self, stage):
        (self.work / f'.done-{stage}').write_text(datetime.datetime.now().isoformat())

    def check_state(self):
        self.work.mkdir(parents=True, exist_ok=True)
        state_file = self.work / 'state.json'
        revision = output(['git', 'rev-parse', self.args.revision], cwd=REPO_ROOT)
        previous = json.loads(state_file.read_text()) if state_file.exists() else None
        if self.args.build_number is None:
            self.args.build_number = (previous or {}).get('build_number') or \
                datetime.date.today().strftime('%Y%m%d') + '01'
        state = {'version': self.version, 'revision': revision, 'build_number': self.args.build_number}
        if previous:
            if previous != state:
                sys.exit(f'Work directory {self.work} was prepared for {previous}; '
                         f'use another --workdir or remove it for {state}.')
        state_file.write_text(json.dumps(state, indent=2))
        self.revision = revision
        if output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=REPO_ROOT):
            log('Note: uncommitted changes are NOT included; the release uses ' + revision[:9])

    def prepare(self):
        if self.done('prepare'):
            return log('prepare: already done')
        log(f'prepare: exporting {self.revision[:9]}')
        for path in (self.export, self.publish_dir):
            if path.exists():
                shutil.rmtree(path)
        self.export.mkdir()
        archive = self.work / 'export.tar'
        run(['git', 'archive', self.revision, '--format=tar', '-o', str(archive)], cwd=REPO_ROOT)
        run(['tar', '-xf', str(archive), '-C', str(self.export)])
        archive.unlink()
        if (self.export / 'opusdocs').exists():
            sys.exit('opusdocs/ leaked into git archive; check .gitattributes export-ignore')
        removed = []
        for relative in PRIVATE_FIXTURE_DIRS:
            if (self.export / relative).exists():
                shutil.rmtree(self.export / relative)
                removed.append(relative)
        for path in self.export.rglob('*.dart'):
            if PRIVATE_FIXTURE_REF.search(path.read_text(encoding='utf-8')):
                path.unlink()
                removed.append(str(path.relative_to(self.export)))
        sanitized = []
        for path in self.export.rglob('*'):
            if not path.is_file() or path.is_symlink():
                continue
            raw = path.read_bytes()
            try:
                text = raw.decode('utf-8')
            except UnicodeDecodeError:
                continue
            new = self.private.sanitize(text)
            if new != text:
                path.write_bytes(new.encode('utf-8'))  # bytes keep CRLF files intact
                sanitized.append(str(path.relative_to(self.export)))
        hits = scan_tree(self.export, self.private)
        (self.work / 'prepare-receipt.json').write_text(json.dumps(
            {'revision': self.revision, 'removed': removed, 'sanitized': sanitized, 'privacy_hits': hits},
            ensure_ascii=False, indent=2))
        if hits:
            sys.exit(f'prepare: privacy scan found {len(hits)} files, see prepare-receipt.json')
        log(f'prepare: removed {len(removed)} private paths, sanitized {len(sanitized)} files, scan 0 hits')
        run(['git', 'clone', '-q', f'https://github.com/{PUBLIC_REPO}.git', str(self.publish_dir)])
        run(['rsync', '-a', '--delete', '--exclude', '.git', f'{self.export}/', f'{self.publish_dir}/'])
        run([sys.executable, f'{APP_REL}/tool/test_release_hygiene.py'], cwd=self.publish_dir,
            log_file=self.work / 'hygiene.log')
        changed = output(['git', 'status', '--porcelain'], cwd=self.publish_dir).splitlines()
        log(f'prepare: public checkout synced, {len(changed)} paths changed, hygiene test passed')
        self.mark('prepare')

    def start_tests(self):
        if self.args.skip_tests or self.done('test'):
            return None
        log('test: full suite started in background (log: test.log)')
        if self.test_src.exists():
            shutil.rmtree(self.test_src)
        run(['ditto', str(self.export), str(self.test_src)])
        app = self.test_src / APP_REL
        script = (f'tool/flutterw pub get >/dev/null 2>&1; '
                  f'tool/flutterw test --reporter json > "{self.work}/full-tests.jsonl"')
        return subprocess.Popen(['bash', '-c', script], cwd=app,
                                stderr=open(self.work / 'test.log', 'w'))

    def finish_tests(self, process):
        if process is not None:
            process.wait()
            self.summarize_tests()
            self.mark('test')
        summary = self.work / 'test-summary.json'
        if summary.exists():
            data = json.loads(summary.read_text())
            log(f"test: {data['passed']} passed, {data['failed']} failed, {data['skipped']} skipped")

    def summarize_tests(self):
        suites, tests, results = {}, {}, {}
        for line in open(self.work / 'full-tests.jsonl', encoding='utf-8', errors='replace'):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get('type')
            if kind == 'suite':
                suites[event['suite']['id']] = event['suite']['path'].split(f'{APP_REL}/')[-1]
            elif kind == 'testStart':
                tests[event['test']['id']] = event['test']['suiteID']
            elif kind == 'testDone' and not event.get('hidden'):
                results[event['testID']] = 'skip' if event.get('skipped') else event['result']
        counts = Counter(results.values())
        failing = Counter(suites.get(tests.get(k), '?') for k, v in results.items() if v in ('error', 'failure'))
        (self.work / 'test-summary.json').write_text(json.dumps({
            'passed': counts['success'], 'skipped': counts['skip'],
            'failed': counts['error'] + counts['failure'], 'failing_files': dict(failing),
        }, ensure_ascii=False, indent=2))

    def build(self):
        if self.done('build'):
            return log('build: already done')
        if self.build_src.exists():
            shutil.rmtree(self.build_src)
        run(['ditto', str(self.export), str(self.build_src)])
        app = self.build_src / APP_REL
        flags = ['--release', '--build-name', self.version.split('-')[0], '--build-number', self.args.build_number,
                 f'--dart-define=AICOVE_RELEASE_TAG={self.version}']
        log('build: Android APK (log: android-build.log)')
        run(['tool/flutterw', 'build', 'apk', '--target-platform', 'android-arm64', *flags], cwd=app, log_file=self.work / 'android-build.log')
        log('build: macOS app (log: macos-build.log)')
        run(['tool/flutterw', 'build', 'macos', *flags], cwd=app, log_file=self.work / 'macos-build.log')
        log('build: iOS app without code signing (log: ios-build.log)')
        run(['tool/flutterw', 'build', 'ios', '--no-codesign', *flags], cwd=app, log_file=self.work / 'ios-build.log')
        if self.assets.exists():
            shutil.rmtree(self.assets)
        self.assets.mkdir()
        apk = self.assets / self.apk_name
        shutil.copy2(app / 'build/app/outputs/flutter-apk/app-release.apk', apk)
        self.check_apk(apk)
        self.package_mac(app / 'build/macos/Build/Products/Release/AIcove.app')
        self.package_ios(app / 'build/ios/iphoneos/Runner.app')
        sums = []
        for name in (self.apk_name, self.zip_name, self.ipa_name):
            sums.append(f'{hashlib.sha256((self.assets / name).read_bytes()).hexdigest()}  {name}')
        (self.assets / 'SHA256SUMS').write_text('\n'.join(sums) + '\n')
        log('build: assets ready in ' + str(self.assets))
        self.mark('build')

    def check_apk(self, apk):
        hits = []
        with zipfile.ZipFile(apk) as archive:
            abis = {entry.split('/')[1] for entry in archive.namelist() if entry.startswith('lib/')}
            if abis != {'arm64-v8a'}:
                sys.exit(f'build: APK must contain only arm64-v8a native libs, got {sorted(abis)}')
            for entry in archive.namelist():
                # Only Dart code embeds build paths; third-party libs may contain "/home/" legitimately.
                found = self.private.hits(archive.read(entry), include_users_dir=entry.endswith('libapp.so'))
                if found:
                    hits.append(f'{entry}: {found}')
        if hits:
            sys.exit('build: APK privacy scan failed:\n' + '\n'.join(hits))
        apksigner = sorted(Path.home().glob('dev-sdks/android-sdk/build-tools/*/apksigner'))
        if apksigner:
            certs = subprocess.run([str(apksigner[-1]), 'verify', '--print-certs', str(apk)],
                                   capture_output=True, text=True).stdout
            digest = re.search(r'certificate SHA-256 digest: (\w+)', certs)
            log(f"build: APK scan 0 hits, signer SHA-256 {digest.group(1) if digest else 'unknown'}")

    def package_mac(self, source):
        if source.is_symlink() or not source.is_dir():
            sys.exit(f'build: {source} is not a real app directory')
        app = self.work / 'mac-package/AIcove.app'
        if app.parent.exists():
            shutil.rmtree(app.parent)
        app.parent.mkdir()
        run(['ditto', str(source), str(app)])
        strip_macho(app)
        entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(source)],
                                               stderr=subprocess.DEVNULL)
        entitlements_file = self.work / 'mac-entitlements.plist'
        entitlements_file.write_bytes(entitlements)
        run(['codesign', '--force', '--deep', '--sign', '-', '--entitlements', str(entitlements_file),
             '--preserve-metadata=identifier,flags,runtime', str(app)], capture_output=True)
        run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True)
        signed = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)],
                                         stderr=subprocess.DEVNULL)
        if signed != entitlements:
            sys.exit('build: entitlements changed while re-signing the Mac app')
        hits = scan_tree(app, self.private)
        if hits:
            sys.exit(f'build: Mac app privacy scan failed: {hits}')
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(self.assets / self.zip_name)])
        log('build: Mac app stripped, re-signed with original entitlements, scan 0 hits')

    def package_ios(self, source):
        if source.is_symlink() or not source.is_dir():
            sys.exit(f'build: {source} is not a real app directory')
        root = self.work / 'ios-package'
        if root.exists():
            shutil.rmtree(root)
        app = root / 'Payload/Runner.app'
        app.parent.mkdir(parents=True)
        run(['ditto', str(source), str(app)])
        strip_macho(app)
        hits = scan_tree(app, self.private)
        if hits:
            sys.exit(f'build: iOS app privacy scan failed: {hits}')
        run(['ditto', '-c', '-k', '--norsrc', '--keepParent', 'Payload', str(self.assets / self.ipa_name)], cwd=root)
        log('build: iOS app stripped, packed as unsigned IPA, scan 0 hits')

    def release_notes(self):
        notes = Path(self.args.notes).read_text(encoding='utf-8').strip()
        summary_file = self.work / 'test-summary.json'
        if summary_file.exists():
            s = json.loads(summary_file.read_text())
            verify = f"验证：公开源码完整 Flutter 套件 {s['passed']} 通过、{s['failed']} 失败、{s['skipped']} 跳过。"
            if s['failing_files']:
                verify += '失败所在文件：' + '；'.join(f'`{f}`（{n}）' for f, n in s['failing_files'].items()) + '。'
        else:
            verify = '验证：本次未运行完整测试套件。'
        if self.prerelease():
            failed = summary_file.exists() and json.loads(summary_file.read_text())['failed'] > 0
            verify += '因此保留预发布标记，不承诺稳定。' if failed else '测试版保留预发布标记。'
        download = (f'下载：\n'
                    f'- Android APK：{self.version.split("-")[0]}，构建号 {self.args.build_number}；'
                    f'签名证书与之前公开测试版相同。\n'
                    f'- macOS Apple Silicon ZIP：临时签名、未公证，沙盒与网络权限保留。\n'
                    f'- iOS IPA：未签名，需自行签名或侧载安装。\n'
                    f'- Windows x64 ZIP：发布后由 GitHub Actions 构建并追加，约需 15 分钟；未签名，'
                    f'首次运行可能出现 SmartScreen 提示。\n'
                    f'- SHA256SUMS：文件校验值；安装包个人路径扫描 0 命中。')
        text = f'{notes}\n\n{verify}\n\n{download}\n'
        (self.work / 'release-notes.md').write_text(text, encoding='utf-8')
        return text

    def prerelease(self):
        if self.args.prerelease is not None:
            return self.args.prerelease
        summary_file = self.work / 'test-summary.json'
        failed = json.loads(summary_file.read_text())['failed'] if summary_file.exists() else 1
        return '-' in self.version or failed > 0

    def publish(self):
        if not self.args.notes:
            sys.exit('publish: --notes is required')
        if self.done('publish'):
            return log('publish: already done')
        self.release_notes()
        hits = self.private.hits((self.work / 'release-notes.md').read_bytes())
        if hits:
            sys.exit(f'publish: release notes contain private terms {hits}')
        tag = f'v{self.version}'
        git = ['git', '-c', f'user.name={PUBLIC_USER}', '-c', f'user.email={PUBLIC_EMAIL}']
        if output(['git', 'status', '--porcelain'], cwd=self.publish_dir):
            run(['git', 'add', '-A'], cwd=self.publish_dir)
            run([*git, 'commit', '-q', '-m', self.args.commit_message or f'feat: sync {self.version} changes'],
                cwd=self.publish_dir)
        run(['git', 'push', 'origin', 'main'], cwd=self.publish_dir)
        log('publish: public repository pushed ' + output(['git', 'rev-parse', '--short', 'HEAD'], cwd=self.publish_dir))
        cmd = ['gh', 'release', 'create', tag, '-R', PUBLIC_REPO, '--target', 'main',
               '--title', self.args.title or f'AIcove {self.version}',
               '--notes-file', str(self.work / 'release-notes.md'),
               str(self.assets / self.apk_name), str(self.assets / self.zip_name), str(self.assets / self.ipa_name),
               str(self.assets / 'SHA256SUMS')]
        if self.prerelease():
            cmd.insert(4, '--prerelease')
        run(cmd)
        verify_dir = self.work / 'download-verify'
        if verify_dir.exists():
            shutil.rmtree(verify_dir)
        verify_dir.mkdir()
        run(['gh', 'release', 'download', tag, '-R', PUBLIC_REPO], cwd=verify_dir)
        run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=verify_dir)
        log(f'publish: https://github.com/{PUBLIC_REPO}/releases/tag/{tag} (downloaded hashes match)')
        self.mark('publish')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('version', help='release version without the v prefix, e.g. 0.1.0-test.5')
    parser.add_argument('--revision', default='HEAD', help='local commit to publish (default HEAD)')
    parser.add_argument('--build-number', help='default <today>01, kept when resuming a work directory')
    parser.add_argument('--workdir', help='default /private/tmp/aicove-release-<version>')
    parser.add_argument('--skip-tests', action='store_true', help='do not run the full Flutter suite')
    parser.add_argument('--publish', action='store_true', help='push the public repo and create the release')
    parser.add_argument('--notes', help='release notes body (new and improved items); required with --publish')
    parser.add_argument('--title', help='release title, default "AIcove <version>"')
    parser.add_argument('--commit-message', help='public repository commit message')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--prerelease', dest='prerelease', action='store_true', default=None)
    group.add_argument('--no-prerelease', dest='prerelease', action='store_false')
    args = parser.parse_args()
    if '/' in args.version or args.version.startswith('v'):
        parser.error('version looks like "0.1.0-test.5" (no v prefix)')
    release = Release(args)
    release.check_state()
    release.prepare()
    tests = release.start_tests()
    try:
        release.build()
    except BaseException:
        if tests is not None:
            tests.terminate()
        raise
    release.finish_tests(tests)
    if args.publish:
        release.publish()
    else:
        log(f'Done without publishing. Review {release.work}, then rerun with --notes <file> --publish.')


if __name__ == '__main__':
    main()
