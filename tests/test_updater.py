"""Run isolated updater transactions with real files and mocked external services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'install.sh'


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='v2bx-geo-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.geo = self.root / 'geo'
        self.geo.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, V2BX_DIR=str(self.geo),
                        V2BX_GEO_BACKUP_DIR=str(self.root / 'backup'),
                        V2BX_GEO_STATE_DIR=str(self.root / 'state'),
                        V2BX_GEO_UPDATER=str(self.root / 'installed' / 'updater'),
                        V2BX_GEO_MANAGER=str(self.root / 'installed' / 'manager'),
                        V2BX_GEO_UNIT_DIR=str(self.root / 'units'),
                        TEST_ROOT=str(self.root), PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.old = {}
        for name in ('geoip.dat', 'geosite.dat'):
            self.old[name] = f'old-{name}'.encode()
            (self.geo / name).write_bytes(self.old[name])
        self.functions = SOURCE
        self.mock('logger', '#!/bin/sh\nexit 0\n')
        self.mock('sleep', '#!/bin/sh\nexit 0\n')
        self.mock('curl', '''#!/usr/bin/env python3
import hashlib, os, pathlib, sys
a = sys.argv[1:]
if '--write-out' in a:
    if os.environ.get('BAD_RELEASE'):
        print('https://example.com/untrusted/geoip.dat', end='')
        sys.exit(0)
    print('https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202610152206/geoip.dat', end='')
    sys.exit(0)
out = pathlib.Path(a[a.index('-o') + 1])
name = a[-1].rsplit('/', 1)[-1]
if os.environ.get('FAIL_DOWNLOAD') == name:
    sys.exit(22)
if name == 'install.sh':
    out.write_bytes((pathlib.Path(os.environ['TEST_ROOT']) / 'remote.sh').read_bytes())
    sys.exit(0)
assert '/releases/download/202610152206/' in a[-1], 'release must be pinned'
base = name.removesuffix('.sha256sum')
data = (('new-' + base) * 300).encode()
if os.environ.get('UNCHANGED'):
    data = ('old-' + base).encode() * 300
if name.endswith('.sha256sum'):
    digest = hashlib.sha256(data).hexdigest()
    if os.environ.get('BAD_HASH') == base:
        digest = '0' * 64
    if os.environ.get('MALFORMED_HASH') == base:
        digest = 'invalid'
    out.write_text(digest + '  ' + base + '\\n')
else:
    out.write_bytes(data)
''')
        self.mock('systemctl', '''#!/bin/sh
echo "$*" >> "$TEST_ROOT/calls"
if [ "$1" = show ]; then
  case "$*" in
    *NextElapseUSecRealtime*) echo 'Fri 2026-10-16 20:00:00 UTC' ;;
    *LastTriggerUSec*) echo "${TIMER_LAST:-n/a}" ;;
    *ExecMainStartTimestamp*) echo "${SERVICE_LAST:-n/a}" ;;
  esac
elif [ "$1" = is-active ]; then
  if [ "${DIE_AFTER_RESTART:-0}" = 1 ] && [ -f "$TEST_ROOT/restarted" ]; then
    exit 3
  fi
  [ "${INACTIVE:-0}" != 1 ]
elif [ "$1" = restart ]; then
  if [ "${DIE_AFTER_RESTART:-0}" = 1 ]; then
    touch "$TEST_ROOT/restarted"
  fi
  if [ "${FAIL_RESTART:-0}" = 1 ] && [ ! -f "$TEST_ROOT/restarted" ]; then
    touch "$TEST_ROOT/restarted"
    exit 1
  fi
fi
''')

    def mock(self, name, contents):
        path = self.bin / name
        path.write_text(contents)
        path.chmod(0o755)

    def update(self, **env):
        return self.run_function('update_geo', **env)

    def run_function(self, body, **env):
        return subprocess.run(['bash', '-c', 'source "$1"; require_root() { return 0; }; ' + body, '_',
                               str(self.functions), str(SOURCE)], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=15)

    def state(self):
        return dict(line.split('\t', 1) for line in (self.root / 'state' / 'status').read_text().splitlines())

    def installed_pair(self, version='1.3.0'):
        old = SOURCE.read_text().replace("VERSION='1.3.0'", f"VERSION='{version}'")
        for key in ('V2BX_GEO_UPDATER', 'V2BX_GEO_MANAGER'):
            path = Path(self.env[key])
            path.parent.mkdir(exist_ok=True)
            path.write_text(old)
        return old

    def remote_version(self, version):
        (self.root / 'remote.sh').write_text(SOURCE.read_text().replace("VERSION='1.3.0'", f"VERSION='{version}'"))

    def test_status_converts_utc_to_beijing_in_any_timezone(self):
        for zone in ('UTC', 'America/Los_Angeles', 'Asia/Tokyo'):
            with self.subTest(zone=zone):
                result = self.run_function('show_status', TZ=zone, TIMER_LAST='Thu 2026-10-15 20:00:00 UTC')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('下次执行：2026-10-17 04:00:00 北京时间', result.stdout)
                self.assertIn('上次执行：2026-10-16 04:00:00 北京时间', result.stdout)

    def test_legacy_service_timestamp_fallback(self):
        result = self.run_function('show_status', SERVICE_LAST='Fri 2026-10-16 10:00:00 UTC')
        self.assertIn('上次执行：2026-10-16 18:00:00 北京时间', result.stdout)

    def test_manual_update_persists_success_and_logs(self):
        self.assertEqual(self.update().returncode, 0)
        state = self.state()
        self.assertEqual(state['result'], 'updated')
        self.assertGreater(int(state['success']), 0)
        result = self.run_function('show_status; show_log')
        self.assertIn('上次结果：成功，Geo 文件已更新', result.stdout)
        self.assertNotIn('尚无成功记录', result.stdout)
        self.assertIn('SHA-256 校验通过', result.stdout)
        self.assertIn('北京时间', result.stdout)

    def test_failed_update_retains_last_success(self):
        self.assertEqual(self.update().returncode, 0)
        success = self.state()['success']
        self.assertNotEqual(self.update(FAIL_DOWNLOAD='geosite.dat').returncode, 0)
        self.assertEqual(self.state()['result'], 'failed')
        self.assertEqual(self.state()['success'], success)

    def test_incomplete_recovery_blocks_next_update_and_preserves_backups(self):
        state_dir = self.root / 'state'
        state_dir.mkdir()
        backup = self.root / 'backup'
        backup.mkdir()
        saved = backup / 'geoip.dat.previous'
        saved.write_bytes(b'last-known-good')
        for previous_result in ('recovery_failed', 'running'):
            with self.subTest(result=previous_result):
                (state_dir / 'status').write_text(f'attempt\t1\nsuccess\t0\nresult\t{previous_result}\n')
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('保护备份', result.stdout)
                self.assertEqual(saved.read_bytes(), b'last-known-good')
                self.assert_originals()

    def test_pinned_release_rejects_unexpected_redirect(self):
        self.assertNotEqual(self.update(BAD_RELEASE='1').returncode, 0)
        self.assert_originals()

    def test_directory_target_is_rejected(self):
        (self.geo / 'geosite.dat').unlink()
        (self.geo / 'geosite.dat').mkdir()
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual((self.geo / 'geoip.dat').read_bytes(), self.old['geoip.dat'])

    def test_symlink_target_is_rejected(self):
        external = self.root / 'external'
        external.write_bytes(b'untouched')
        (self.geo / 'geosite.dat').unlink()
        (self.geo / 'geosite.dat').symlink_to(external)
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(external.read_bytes(), b'untouched')

    def test_early_exit_after_restart_is_detected(self):
        result = self.update(DIE_AFTER_RESTART='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_originals()
        self.assertIn('原文件恢复后 V2bX 仍未恢复', result.stdout)

    def test_self_update_replaces_both_scripts(self):
        self.installed_pair()
        self.remote_version('1.4.0')
        result = self.run_function('self_update')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for key in ('V2BX_GEO_UPDATER', 'V2BX_GEO_MANAGER'):
            self.assertIn("VERSION='1.4.0'", Path(self.env[key]).read_text())
        self.assert_originals()
        self.assertFalse(self.calls.exists())

    def test_self_update_no_downgrade(self):
        old = self.installed_pair()
        self.remote_version('1.2.0')
        self.assertNotEqual(self.run_function('self_update').returncode, 0)
        self.assertEqual(Path(self.env['V2BX_GEO_MANAGER']).read_text(), old)

    def test_self_update_same_version_no_change(self):
        old = self.installed_pair()
        self.remote_version('1.3.0')
        result = self.run_function('self_update')
        self.assertEqual(result.returncode, 0)
        self.assertIn('当前已是最新版本', result.stdout)
        self.assertEqual(Path(self.env['V2BX_GEO_MANAGER']).read_text(), old)

    def test_self_update_bad_payloads_preserve_current_scripts(self):
        old = self.installed_pair()
        for payload in ('<!doctype html>', '#!/bin/bash\necho unwanted\n',
                        '# V2BX_GEO_SCRIPT\nVERSION=oops\n', '# V2BX_GEO_SCRIPT\nif (\n'):
            with self.subTest(payload=payload):
                (self.root / 'remote.sh').write_text(payload)
                self.assertNotEqual(self.run_function('self_update').returncode, 0)
                for key in ('V2BX_GEO_UPDATER', 'V2BX_GEO_MANAGER'):
                    self.assertEqual(Path(self.env[key]).read_text(), old)

    def test_self_update_network_failure_preserves_current_scripts(self):
        old = self.installed_pair()
        self.assertNotEqual(self.run_function('self_update', FAIL_DOWNLOAD='install.sh').returncode, 0)
        self.assertEqual(Path(self.env['V2BX_GEO_MANAGER']).read_text(), old)

    def test_self_update_second_replace_failure_restores_both(self):
        old = self.installed_pair()
        self.remote_version('1.4.0')
        self.mock('mv', '''#!/bin/sh
case "$*" in
  *manager.new*)
    if [ ! -f "$TEST_ROOT/move-failed" ]; then
      touch "$TEST_ROOT/move-failed"
      exit 1
    fi ;;
esac
exec /usr/bin/mv "$@"
''')
        self.assertNotEqual(self.run_function('self_update').returncode, 0)
        for key in ('V2BX_GEO_UPDATER', 'V2BX_GEO_MANAGER'):
            self.assertEqual(Path(self.env[key]).read_text(), old)

    def test_uninstall_preserves_geo_and_history(self):
        self.installed_pair()
        self.assertEqual(self.update().returncode, 0)
        files = {name: (self.geo / name).read_bytes() for name in self.old}
        result = self.run_function('uninstall_geo')
        self.assertEqual(result.returncode, 0, result.stderr)
        for name, data in files.items():
            self.assertEqual((self.geo / name).read_bytes(), data)
        self.assertTrue((self.root / 'state' / 'status').exists())
        self.assertTrue((self.root / 'backup' / 'geoip.dat.previous').exists())
        self.assertFalse(Path(self.env['V2BX_GEO_MANAGER']).exists())

    def test_uninstall_works_when_v2bx_directory_is_missing(self):
        import shutil
        self.installed_pair()
        shutil.rmtree(self.geo)
        result = self.run_function('uninstall_geo')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(self.env['V2BX_GEO_MANAGER']).exists())

    def test_log_rotation(self):
        state_dir = self.root / 'state'
        state_dir.mkdir()
        (state_dir / 'update.log').write_bytes(b'x' * 1048576)
        self.assertEqual(self.update().returncode, 0)
        self.assertEqual((state_dir / 'update.log.1').stat().st_size, 1048576)
        self.assertLess((state_dir / 'update.log').stat().st_size, 1048576)

    @unittest.skipUnless(os.geteuid() == 0, 'isolated installation launches a root-only child')
    def test_install_generates_valid_units_and_keeps_existing_data(self):
        result = self.run_function('install_dependencies() { return 0; }; script_path="$2"; install_geo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        service = self.root / 'units' / 'v2bx-geo-update.service'
        timer = self.root / 'units' / 'v2bx-geo-update.timer'
        self.assertIn('TimeoutStartSec=2h', service.read_text())
        self.assertIn('Environment="V2BX_GEO_STATE_DIR=' + str(self.root / 'state') + '"', service.read_text())
        self.assertIn('04:00:00 Asia/Shanghai', timer.read_text())
        verified = subprocess.run(['systemd-analyze', 'verify', str(service), str(timer)],
                                  capture_output=True, text=True, timeout=15)
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
        self.assertEqual(self.state()['result'], 'updated')

    @unittest.skipUnless(os.geteuid() == 0, 'isolated installation launches a root-only child')
    def test_initial_download_failure_still_enables_timer_and_reports_failure(self):
        result = self.run_function('install_dependencies() { return 0; }; script_path="$2"; install_geo',
                                   FAIL_DOWNLOAD='geoip.dat')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('首次更新失败', result.stderr)
        self.assertIn('enable --now v2bx-geo-update.timer', self.calls.read_text())
        self.assert_originals()
        self.assertEqual(self.state()['result'], 'failed')

    def test_signal_during_second_replace_rolls_back(self):
        self.mock('mv', '''#!/bin/sh
case "$*" in
  *geosite.dat.v2bx.new*)
    if [ ! -f "$TEST_ROOT/signalled" ]; then
      touch "$TEST_ROOT/signalled"
      kill -TERM "$PPID"
      exit 1
    fi ;;
esac
exec /usr/bin/mv "$@"
''')
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_originals()
        self.assertEqual(self.state()['result'], 'failed')

    def test_file_information_uses_beijing_time(self):
        import datetime
        epoch = int(datetime.datetime(2026, 10, 16, 20, tzinfo=datetime.timezone.utc).timestamp())
        for name in self.old:
            os.utime(self.geo / name, (epoch, epoch))
        result = self.run_function('show_geo_info', TZ='America/Los_Angeles')
        self.assertEqual(result.stdout.count('2026-10-17 04:00:00 北京时间'), 2)

    def test_self_update_and_uninstall_obey_geo_lock(self):
        import fcntl
        self.installed_pair()
        (self.root / 'state').mkdir(exist_ok=True)
        with (self.root / 'state' / '.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for action in ('self_update', 'uninstall_geo'):
                self.assertNotEqual(self.run_function(action).returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertTrue(Path(self.env['V2BX_GEO_MANAGER']).exists())

    def assert_originals(self):
        for name, data in self.old.items():
            self.assertEqual((self.geo / name).read_bytes(), data)

    def test_success_and_backup(self):
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name, data in self.old.items():
            self.assertEqual((self.root / 'backup' / (name + '.previous')).read_bytes(), data)
            self.assertEqual((self.geo / name).read_bytes(), (('new-' + name) * 300).encode())
        self.assertEqual(self.calls.read_text().count('restart V2bX.service'), 1)

    def test_second_download_failure_preserves_both(self):
        self.assertNotEqual(self.update(FAIL_DOWNLOAD='geosite.dat').returncode, 0)
        self.assert_originals()
        self.assertFalse(self.calls.exists())

    def test_checksum_download_failure(self):
        self.assertNotEqual(self.update(FAIL_DOWNLOAD='geoip.dat.sha256sum').returncode, 0)
        self.assert_originals()

    def test_corrupt_file_preserves_both(self):
        self.assertNotEqual(self.update(BAD_HASH='geosite.dat').returncode, 0)
        self.assert_originals()

    def test_malformed_checksum_preserves_both(self):
        self.assertNotEqual(self.update(MALFORMED_HASH='geoip.dat').returncode, 0)
        self.assert_originals()

    def test_second_replace_failure_rolls_back(self):
        self.mock('mv', '''#!/bin/sh
case "$*" in
  *geosite.dat.v2bx.new*)
    if [ ! -f "$TEST_ROOT/move-failed" ]; then
      touch "$TEST_ROOT/move-failed"
      exit 1
    fi ;;
esac
exec /usr/bin/mv "$@"
''')
        self.assertNotEqual(self.update().returncode, 0)
        self.assert_originals()
        self.assertFalse(self.calls.exists())

    def test_first_install_restart_failure_removes_new_files(self):
        for name in self.old:
            (self.geo / name).unlink()
        self.assertNotEqual(self.update(FAIL_RESTART='1').returncode, 0)
        for name in self.old:
            self.assertFalse((self.geo / name).exists())

    def test_restart_failure_rolls_back(self):
        result = self.update(FAIL_RESTART='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_originals()
        self.assertEqual(self.calls.read_text().count('restart V2bX.service'), 2)

    def test_inactive_service_stays_stopped(self):
        self.assertEqual(self.update(INACTIVE='1').returncode, 0)
        self.assertNotIn('restart', self.calls.read_text())

    def test_unchanged_files_skip_restart(self):
        for name in self.old:
            (self.geo / name).write_bytes((('old-' + name) * 300).encode())
        self.assertEqual(self.update(UNCHANGED='1').returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_concurrent_update_rejected(self):
        import fcntl
        (self.root / 'state').mkdir(exist_ok=True)
        with (self.root / 'state' / '.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('另一个 Geo 管理任务', result.stdout)
        self.assert_originals()

    def test_rollback_failure_reported(self):
        self.mock('install', '''#!/bin/sh
case "$*" in
  *geoip.previous*.v2bx.new*) exit 1 ;;
esac
exec /usr/bin/install "$@"
''')
        result = self.update(FAIL_RESTART='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('回滚未完成', result.stdout)
        self.assertEqual(self.calls.read_text().count('restart V2bX.service'), 1)
        self.assertTrue((self.root / 'backup' / 'geoip.dat.previous').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
