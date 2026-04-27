#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ADB: Path | None = None
READY_MARKER = 'STORE_SCREENSHOT_READY '
DONE_MARKER = 'STORE_SCREENSHOT_DONE'


@dataclass(frozen=True)
class ScreenshotTarget:
    name: str
    platform: str
    size: tuple[int, int]
    simulator_name: str | None = None
    android_size: str | None = None
    android_density: str | None = None


TARGETS = {
    'ios_phone': ScreenshotTarget(
        name='ios_phone',
        platform='ios',
        simulator_name='iPhone 17 Pro Max',
        size=(1320, 2868),
    ),
    'ios_ipad': ScreenshotTarget(
        name='ios_ipad',
        platform='ios',
        simulator_name='iPad Pro 13-inch (M5)',
        size=(2064, 2752),
    ),
    'android_phone': ScreenshotTarget(
        name='android_phone',
        platform='android',
        size=(1440, 2560),
        android_size='1440x2560',
        android_density='560',
    ),
    'android_7_tablet': ScreenshotTarget(
        name='android_7_tablet',
        platform='android',
        size=(1200, 1920),
        android_size='1200x1920',
        android_density='240',
    ),
    'android_10_tablet': ScreenshotTarget(
        name='android_10_tablet',
        platform='android',
        size=(1600, 2560),
        android_size='1600x2560',
        android_density='320',
    ),
}


def main() -> None:
    _prefer_stable_xcode()
    args = _parse_args()
    targets = _targets_for_platform(args.platform)
    with StoreDemoEnvironment() as demo:
        for target in targets:
            _run_target(target, demo)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Capture real MonkeySSH app screenshots into Fastlane folders.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which store screenshot set to generate.',
    )
    return parser.parse_args()


def _targets_for_platform(platform: str) -> list[ScreenshotTarget]:
    if platform == 'ios':
        return [TARGETS['ios_phone'], TARGETS['ios_ipad']]
    if platform == 'android':
        return [
            TARGETS['android_phone'],
            TARGETS['android_7_tablet'],
            TARGETS['android_10_tablet'],
        ]
    return list(TARGETS.values())


def _run_target(target: ScreenshotTarget, demo: StoreDemoEnvironment) -> None:
    print(f'Generating {target.name} screenshots...')
    demo.reset_tmux()
    if target.platform == 'ios':
        device_id = _boot_ios_simulator(_ios_simulator_name(target))
        _reset_ios_app_state(device_id)
        restore_android = None
    else:
        device_id = _android_device_id()
        restore_android = _configure_android_display(target, device_id)

    try:
        _run_flutter_capture(target, device_id, demo)
    finally:
        if restore_android is not None:
            restore_android()


def _run_flutter_capture(
    target: ScreenshotTarget,
    device_id: str,
    demo: StoreDemoEnvironment,
) -> None:
    env = os.environ.copy()
    java_home = _java_home_17()
    if java_home:
        env['JAVA_HOME'] = java_home

    command = [
        'flutter',
        'run',
        '--debug',
        '-d',
        device_id,
        '-t',
        'tool/store_screenshot_app.dart',
        f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PORT={demo.port}',
        f'--dart-define=STORE_SCREENSHOT_SSH_USERNAME={demo.username}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64={demo.private_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_B64={demo.host_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT={demo.host_key_fingerprint}',
        f'--dart-define=STORE_SCREENSHOT_TMUX_SESSION={demo.tmux_session}',
        '--dart-define=STORE_SCREENSHOT_REDACT_IDENTITIES=true',
        '--dart-define=STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR=true',
        '--dart-define=STORE_SCREENSHOT_DISABLE_NOTIFICATIONS=true',
    ]
    if target.platform in ('android', 'ios'):
        command.extend(['--flavor', 'production'])

    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None

    saw_done = False
    try:
        for raw_line in process.stdout:
            print(raw_line, end='')
            line = raw_line.strip()
            if READY_MARKER in line:
                payload = json.loads(line.split(READY_MARKER, 1)[1])
                time.sleep(0.4)
                _capture_native_screenshot(
                    target=target,
                    device_id=device_id,
                    paths=[ROOT / path for path in payload['paths']],
                )
            if DONE_MARKER in line:
                saw_done = True
                break
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=20)

    if not saw_done:
        if process.returncode not in (0, None):
            raise subprocess.CalledProcessError(process.returncode, command)
        raise RuntimeError(f'{target.name} run ended before all screenshots were captured')


class StoreDemoEnvironment:
    def __init__(self) -> None:
        self._tmpdir = Path(tempfile.mkdtemp(prefix='monkeyssh-store-demo-'))
        self.username = getpass.getuser()
        self.port = _free_local_port()
        self.tmux_session = f'monkeyssh-store-{os.getpid()}'
        self.demo_dir = Path('/Users/Shared/monkeyssh-release-workspace')
        self._process: subprocess.Popen[str] | None = None
        self._tmux = shutil.which('tmux')
        if self._tmux is None:
            raise RuntimeError('tmux is required for the release-demo SSH workspace.')
        self._copilot = shutil.which('copilot')
        if self._copilot is None:
            raise RuntimeError('GitHub Copilot CLI is required for the first store screenshot.')
        self._claude = shutil.which('claude')
        if self._claude is None:
            raise RuntimeError('Claude Code CLI is required for the Claude store screenshot.')
        self._clean_claude_home = self._tmpdir / 'claude-home'

    @property
    def private_key_b64(self) -> str:
        return base64.b64encode((self._tmpdir / 'client_key').read_bytes()).decode()

    @property
    def host_key_b64(self) -> str:
        return (self._tmpdir / 'host_key.pub').read_text().split()[1]

    @property
    def host_key_fingerprint(self) -> str:
        digest = hashlib.sha256(base64.b64decode(self.host_key_b64)).digest()
        return f'SHA256:{base64.b64encode(digest).decode().rstrip("=")}'

    def __enter__(self) -> StoreDemoEnvironment:
        self._create_keys()
        self._start_sshd()
        self._setup_tmux()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self._teardown_tmux()
        self._stop_sshd()
        self._remove_demo_dir()
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def reset_tmux(self) -> None:
        subprocess.run(
            [self._tmux or 'tmux', 'select-window', '-t', f'{self.tmux_session}:copilot'],
            check=False,
        )

    def _create_keys(self) -> None:
        host_key = self._tmpdir / 'host_key'
        client_key = self._tmpdir / 'client_key'
        subprocess.run(
            ['ssh-keygen', '-t', 'ed25519', '-f', str(host_key), '-N', '', '-q'],
            check=True,
        )
        subprocess.run(
            [
                'ssh-keygen',
                '-t',
                'ed25519',
                '-f',
                str(client_key),
                '-N',
                '',
                '-C',
                'monkeyssh-release-workspace',
                '-q',
            ],
            check=True,
        )
        authorized_keys = self._tmpdir / 'authorized_keys'
        authorized_keys.write_text((self._tmpdir / 'client_key.pub').read_text())
        os.chmod(client_key, 0o600)
        os.chmod(authorized_keys, 0o600)

    def _start_sshd(self) -> None:
        config = self._tmpdir / 'sshd_config'
        config.write_text(
            '\n'.join(
                [
                    f'Port {self.port}',
                    'ListenAddress 127.0.0.1',
                    f'HostKey {self._tmpdir / "host_key"}',
                    f'PidFile {self._tmpdir / "sshd.pid"}',
                    f'AuthorizedKeysFile {self._tmpdir / "authorized_keys"}',
                    'PasswordAuthentication no',
                    'ChallengeResponseAuthentication no',
                    'KbdInteractiveAuthentication no',
                    'UsePAM no',
                    'PermitRootLogin no',
                    'StrictModes no',
                    f'AllowUsers {self.username}',
                    'PermitTTY yes',
                    'Subsystem sftp internal-sftp',
                    'LogLevel ERROR',
                    '',
                ]
            )
        )
        subprocess.run(['/usr/sbin/sshd', '-t', '-f', str(config)], check=True)
        self._process = subprocess.Popen(
            ['/usr/sbin/sshd', '-D', '-e', '-f', str(config)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self._wait_for_sshd()

    def _wait_for_sshd(self) -> None:
        command = [
            'ssh',
            '-i',
            str(self._tmpdir / 'client_key'),
            '-p',
            str(self.port),
            '-o',
            'BatchMode=yes',
            '-o',
            'StrictHostKeyChecking=no',
            '-o',
            'UserKnownHostsFile=/dev/null',
            f'{self.username}@127.0.0.1',
            'true',
        ]
        deadline = time.time() + 10
        while time.time() < deadline:
            if self._process is not None and self._process.poll() is not None:
                output = self._process.stdout.read() if self._process.stdout else ''
                raise RuntimeError(f'sshd exited before accepting connections: {output}')
            result = subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if result.returncode == 0:
                return
            time.sleep(0.2)
        raise RuntimeError(f'Timed out waiting for demo sshd on port {self.port}')

    def _setup_tmux(self) -> None:
        self._prepare_demo_dir()
        self._teardown_tmux()
        self._write_pane_script(
            'copilot',
            f"""
            exec env COPILOT_ALLOW_ALL=0 \\
              {self._shell_quote(self._copilot)} \\
              --no-remote \\
              --log-level none \\
              --secret-env-vars=USER,EMAIL,GITHUB_TOKEN,GH_TOKEN,ANTHROPIC_API_KEY \\
              --name 'Mobile Copilot Workspace'
            """,
        )
        self._write_pane_script(
            'claude',
            f"""
            exec env -i \\
              PATH={self._shell_quote(os.environ.get('PATH', ''))} \\
              TERM=xterm-256color \\
              HOME={self._shell_quote(str(self._clean_claude_home))} \\
              BASH_SILENCE_DEPRECATION_WARNING=1 \\
              CLAUDE_CODE_HIDE_ACCOUNT_INFO=1 \\
              CLAUDE_CODE_HIDE_CWD=1 \\
              ANTHROPIC_API_KEY=sk-ant-api03-0000000000000000000000000000000000000000000000000000000000000000-dummy \\
              {self._shell_quote(self._claude)} \\
              --bare \\
              --name 'Claude Code Workspace'
            """,
        )
        self._write_pane_script(
            'gemini',
            """
            clear
            printf 'Gemini agent session ready\\n'
            printf 'Open inside MonkeySSH when you need a second reviewer.\\n'
            """,
        )
        self._write_pane_script(
            'codex',
            """
            clear
            printf 'Codex agent session ready\\n'
            printf 'Keep long-running coding sessions alive in tmux.\\n'
            """,
        )
        self._start_tmux_windows()
        self._configure_tmux_status()
        self._drive_copilot_start_screen()
        self._drive_claude_full_screen()
        self.reset_tmux()

    def _prepare_demo_dir(self) -> None:
        marker = self.demo_dir / '.monkeyssh-release-workspace'
        if self.demo_dir.exists():
            if not marker.exists():
                raise RuntimeError(
                    f'{self.demo_dir} already exists and was not created by this script.',
                )
            shutil.rmtree(self.demo_dir)
        self.demo_dir.mkdir(parents=True)
        marker.write_text('release screenshot demo workspace\n')
        (self.demo_dir / 'AGENTS.md').write_text(
            '\n'.join(
                [
                    '# Agent workspace',
                    '',
                    'Use this streamer-safe workspace for release screenshots.',
                    '',
                    '- Do not show emails, usernames, hostnames, tokens, or private identifiers.',
                    '- Prefer concise checks that fit in a mobile terminal screenshot.',
                    '- Keep terminal output focused on SSH, tmux, agent, and store asset workflows.',
                    '',
                    'Windows:',
                    '1. copilot - GitHub Copilot CLI',
                    '2. gemini  - Gemini CLI workspace',
                    '3. claude  - Claude Code workspace',
                    '4. codex   - Codex CLI workspace',
                    '',
                ]
            )
        )
        (self.demo_dir / 'reconnect_plan.md').write_text(
            '\n'.join(
                [
                    '# SSH terminal reconnect plan',
                    '',
                    '- Verify keepalive settings detect dropped links promptly.',
                    '- Confirm tmux reattach restores the same shell, panes, and scrollback.',
                    '- Validate reconnect behavior after suspend, network change, and app resume.',
                    '- Keep logs streamer-safe by hiding account and host identifiers.',
                    '',
                ]
            )
        )
        (self.demo_dir / 'store_assets.md').write_text(
            '\n'.join(
                [
                    '# Store screenshot assets',
                    '',
                    '| Platform | Form factors | Scenes |',
                    '| --- | --- | --- |',
                    '| App Store | iPhone 6.9, iPad 13 | Copilot, hosts, snippets, tmux selector, SFTP, Claude Code |',
                    '| Google Play | Phone, 7-inch tablet, 10-inch tablet | Same scene order for production and private tracks |',
                    '',
                    'Validation checklist:',
                    '',
                    '- Capture from the normal MonkeySSH app, not a direct-mounted screen harness.',
                    '- Use a live SSH connection into this tmux workspace.',
                    '- Avoid subscription or checkout screens.',
                    '- Scan visible output for emails, usernames, tokens, and private identifiers.',
                    '',
                    '',
                ]
            )
        )

    def _remove_demo_dir(self) -> None:
        marker = self.demo_dir / '.monkeyssh-release-workspace'
        if marker.exists():
            shutil.rmtree(self.demo_dir, ignore_errors=True)

    def _start_tmux_windows(self) -> None:
        self._tmux_run(
            'new-session',
            '-d',
            '-s',
            self.tmux_session,
            '-n',
            'copilot',
            '-c',
            str(self.demo_dir),
            str(self._tmpdir / 'copilot-pane.sh'),
        )
        self._tmux_run(
            'new-window',
            '-t',
            self.tmux_session,
            '-n',
            'gemini',
            '-c',
            str(self.demo_dir),
            str(self._tmpdir / 'gemini-pane.sh'),
        )
        self._tmux_run(
            'new-window',
            '-t',
            self.tmux_session,
            '-n',
            'claude',
            '-c',
            str(self.demo_dir),
            str(self._tmpdir / 'claude-pane.sh'),
        )
        self._tmux_run(
            'new-window',
            '-t',
            self.tmux_session,
            '-n',
            'codex',
            '-c',
            str(self.demo_dir),
            str(self._tmpdir / 'codex-pane.sh'),
        )

    def _write_pane_script(self, window: str, body: str) -> None:
        rcfile = self._tmpdir / f'{window}-bashrc'
        rcfile.write_text(
            '\n'.join(
                [
                    'export BASH_SILENCE_DEPRECATION_WARNING=1',
                    f"PS1='release-workspace {window} % '",
                    '',
                ]
            )
        )
        script = self._tmpdir / f'{window}-pane.sh'
        script.write_text(
            '\n'.join(
                [
                    '#!/bin/bash',
                    'set -e',
                    'export BASH_SILENCE_DEPRECATION_WARNING=1',
                    f'cd {self.demo_dir}',
                    body.strip(),
                    f"exec bash --rcfile {rcfile} -i",
                    '',
                ]
            )
        )
        os.chmod(script, 0o700)

    def _drive_copilot_start_screen(self) -> None:
        time.sleep(4)
        self._tmux_send_keys('copilot', 'Enter')
        time.sleep(8)
        self._ensure_copilot_streamer_mode()
        self._tmux_send_keys('copilot', 'C-l')
        time.sleep(2)
        self._wait_for_visible_text('copilot', ['GitHub Copilot'])
        self._assert_copilot_pane_streamer_safe()

    def _drive_claude_full_screen(self) -> None:
        self._wait_for_visible_text('claude', ['Choose the text style'])
        self._tmux_send_keys('claude', 'Enter')
        self._wait_for_visible_text(
            'claude',
            ['Detected a custom API key', 'ANTHROPIC_API_KEY', 'dummy'],
        )
        self._tmux_send_keys('claude', 'Up', 'Enter')
        self._wait_for_visible_text('claude', ['Press Enter to continue'])
        self._tmux_send_keys('claude', 'Enter')
        self._wait_for_visible_text('claude', ['Yes, I trust this folder'])
        self._tmux_send_keys('claude', 'Enter')
        self._wait_for_visible_text('claude', ['Claude Code'])
        time.sleep(3)
        self._assert_claude_pane_streamer_safe()

    def _ensure_copilot_streamer_mode(self) -> None:
        self._wait_for_visible_text('copilot', ['GitHub Copilot'])
        self._tmux_send_literal('copilot', '/streamer')
        self._tmux_send_keys('copilot', 'Enter')
        time.sleep(4)
        text = self._capture_visible_pane('copilot')
        if 'Streamer mode enabled.' in text:
            return
        if 'Streamer mode disabled.' in text:
            self._tmux_send_literal('copilot', '/streamer')
            self._tmux_send_keys('copilot', 'Enter')
            time.sleep(4)
            text = self._capture_visible_pane('copilot')
            if 'Streamer mode enabled.' in text:
                return
        raise RuntimeError('Could not enable GitHub Copilot CLI streamer mode.')

    def _wait_for_visible_text(self, window: str, markers: list[str]) -> None:
        deadline = time.time() + 30
        while time.time() < deadline:
            text = self._capture_visible_pane(window)
            if all(marker in text for marker in markers):
                return
            time.sleep(1)
        raise RuntimeError(
            f'{window} pane did not show expected text: {", ".join(markers)}.',
        )

    def _assert_copilot_pane_streamer_safe(self) -> None:
        self._assert_pane_privacy_safe('copilot')

    def _assert_claude_pane_streamer_safe(self) -> None:
        self._assert_pane_privacy_safe('claude', allow_billing_label=True)

    def _assert_pane_privacy_safe(
        self,
        window: str,
        *,
        allow_billing_label: bool = False,
    ) -> None:
        text = self._capture_visible_pane(window)
        private_patterns = [
            (r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'email'),
            (
                r'(?:ghp_|github_pat_)[A-Za-z0-9_\-]+|'
                r'sk-[A-Za-z0-9_\-]+',
                'token',
            ),
            (re.escape(str(Path.home())), 'home directory'),
            (rf'\b{re.escape(self.username)}\b', 'local username'),
            (r'\bDavid\b', 'account display name'),
            (r'Organization', 'account organization'),
            (r'ANTHROPIC_API_KEY', 'API key environment label'),
        ]
        if not allow_billing_label:
            private_patterns.append(
                (r'API\s+Usage\s+Billing|Account\s+|Billing', 'billing banner'),
            )
        for pattern, label in private_patterns:
            if re.search(pattern, text, flags=re.IGNORECASE):
                raise RuntimeError(
                    f'{window} pane still shows {label}; refusing to capture store screenshot.',
                )

    def _capture_visible_pane(self, window: str) -> str:
        result = subprocess.run(
            [
                self._tmux or 'tmux',
                'capture-pane',
                '-p',
                '-t',
                f'{self.tmux_session}:{window}',
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        return result.stdout

    def _tmux_run(self, *args: str) -> None:
        subprocess.run([self._tmux or 'tmux', *args], check=True)

    def _tmux_send_keys(self, window: str, *keys: str) -> None:
        self._tmux_run('send-keys', '-t', f'{self.tmux_session}:{window}', *keys)

    def _tmux_send_literal(self, window: str, text: str) -> None:
        self._tmux_run('send-keys', '-t', f'{self.tmux_session}:{window}', '-l', text)

    @staticmethod
    def _shell_quote(value: str) -> str:
        return "'" + value.replace("'", "'\"'\"'") + "'"

    def _configure_tmux_status(self) -> None:
        self._tmux_run('set-option', '-t', self.tmux_session, 'status', 'on')
        self._tmux_run(
            'set-option',
            '-t',
            self.tmux_session,
            'status-left',
            '[MonkeySSH demo] ',
        )
        self._tmux_run('set-option', '-t', self.tmux_session, 'status-right', '%H:%M')
        self._tmux_run(
            'set-option',
            '-t',
            self.tmux_session,
            'window-status-format',
            '#I:#W',
        )
        self._tmux_run(
            'set-option',
            '-t',
            self.tmux_session,
            'window-status-current-format',
            '#I:#W*',
        )

    def _teardown_tmux(self) -> None:
        if self._tmux is None:
            return
        subprocess.run(
            [self._tmux, 'kill-session', '-t', self.tmux_session],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    def _stop_sshd(self) -> None:
        if self._process is None:
            return
        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=10)
        if self._process.stdout is not None:
            self._process.stdout.close()


def _free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return int(sock.getsockname()[1])


def _capture_native_screenshot(
    *,
    target: ScreenshotTarget,
    device_id: str,
    paths: list[Path],
) -> None:
    with tempfile.NamedTemporaryFile(suffix='.png') as tmp:
        tmp_path = Path(tmp.name)
        if target.platform == 'ios':
            subprocess.run(
                ['xcrun', 'simctl', 'io', device_id, 'screenshot', str(tmp_path)],
                cwd=ROOT,
                check=True,
            )
        else:
            result = subprocess.run(
                [str(_adb_path()), '-s', device_id, 'exec-out', 'screencap', '-p'],
                cwd=ROOT,
                check=True,
                stdout=subprocess.PIPE,
            )
            tmp_path.write_bytes(result.stdout)

        with Image.open(tmp_path) as image:
            screenshot = image.convert('RGB')
            if screenshot.size != target.size:
                screenshot = ImageOps.fit(
                    screenshot,
                    target.size,
                    method=Image.Resampling.LANCZOS,
                )
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                screenshot.save(path, optimize=True)
                print(
                    f'Wrote {path.relative_to(ROOT)} '
                    f'({target.size[0]}x{target.size[1]})',
                )


def _boot_ios_simulator(name: str) -> str:
    devices = json.loads(
        subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
    )
    for runtime, runtime_devices in devices['devices'].items():
        if not runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
            continue
        for device in runtime_devices:
            if device['name'] == name:
                device_id = device['udid']
                subprocess.run(['xcrun', 'simctl', 'boot', device_id], check=False)
                subprocess.run(
                    ['xcrun', 'simctl', 'bootstatus', device_id, '-b'],
                    check=True,
                )
                return device_id
    raise RuntimeError(f'Unable to find available iOS simulator named {name!r}')


def _ios_simulator_name(target: ScreenshotTarget) -> str:
    override_name = os.environ.get(
        f'STORE_SCREENSHOT_{target.name.upper()}_SIMULATOR',
    )
    return override_name or target.simulator_name or ''


def _reset_ios_app_state(device_id: str) -> None:
    for bundle_id in (
        'xyz.depollsoft.monkeyssh',
        'xyz.depollsoft.monkeyssh.private',
    ):
        subprocess.run(
            ['xcrun', 'simctl', 'uninstall', device_id, bundle_id],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def _android_device_id() -> str:
    adb = _adb_path()
    result = subprocess.check_output([str(adb), 'devices'], text=True)
    for line in result.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == 'device':
            return parts[0]
    raise RuntimeError('No running Android device or emulator found')


def _configure_android_display(
    target: ScreenshotTarget,
    device_id: str,
):
    adb = _adb_path()
    original_size = subprocess.check_output(
        [str(adb), '-s', device_id, 'shell', 'wm', 'size'],
        text=True,
    )
    original_density = subprocess.check_output(
        [str(adb), '-s', device_id, 'shell', 'wm', 'density'],
        text=True,
    )

    subprocess.run(
        [str(adb), '-s', device_id, 'shell', 'wm', 'size', target.android_size or 'reset'],
        check=True,
    )
    subprocess.run(
        [
            str(adb),
            '-s',
            device_id,
            'shell',
            'wm',
            'density',
            target.android_density or 'reset',
        ],
        check=True,
    )

    def restore() -> None:
        if 'Override size:' in original_size:
            size = original_size.split('Override size:', 1)[1].splitlines()[0].strip()
            subprocess.run([str(adb), '-s', device_id, 'shell', 'wm', 'size', size], check=True)
        else:
            subprocess.run([str(adb), '-s', device_id, 'shell', 'wm', 'size', 'reset'], check=True)

        if 'Override density:' in original_density:
            density = (
                original_density.split('Override density:', 1)[1].splitlines()[0].strip()
            )
            subprocess.run(
                [str(adb), '-s', device_id, 'shell', 'wm', 'density', density],
                check=True,
            )
        else:
            subprocess.run(
                [str(adb), '-s', device_id, 'shell', 'wm', 'density', 'reset'],
                check=True,
            )

    return restore


def _adb_path() -> Path:
    global ADB
    if ADB is not None:
        return ADB

    candidates: list[Path] = []
    for env_var in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        sdk_root = os.environ.get(env_var)
        if sdk_root:
            candidates.append(Path(sdk_root) / 'platform-tools' / 'adb')
    if found_adb := shutil.which('adb'):
        candidates.append(Path(found_adb))
    candidates.append(
        Path.home() / 'Library' / 'Android' / 'sdk' / 'platform-tools' / 'adb',
    )

    for candidate in candidates:
        if candidate.exists():
            ADB = candidate
            return candidate
    raise RuntimeError(
        'adb not found. Set ANDROID_HOME or ANDROID_SDK_ROOT, or put adb on PATH.',
    )


def _java_home_17() -> str | None:
    java_home = shutil.which('/usr/libexec/java_home')
    if java_home is None:
        return None
    result = subprocess.run(
        [java_home, '-v', '17'],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout.strip() or None


def _prefer_stable_xcode() -> None:
    developer_dir = Path('/Applications/Xcode.app/Contents/Developer')
    if developer_dir.exists():
        os.environ['DEVELOPER_DIR'] = str(developer_dir)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'error: {error}', file=sys.stderr)
        raise
