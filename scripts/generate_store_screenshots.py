#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import fcntl
import gzip
import getpass
import hashlib
import json
import os
import platform
import pty
import queue
import re
import shutil
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import struct
import termios
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ADB: Path | None = None
READY_MARKER = 'STORE_SCREENSHOT_READY '
DONE_MARKER = 'STORE_SCREENSHOT_DONE'
ERROR_MARKER = 'STORE_SCREENSHOT_ERROR '
ANSI_ESCAPE_PATTERN = re.compile(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))'
)
KEY_BYTES = {
    'Enter': '\r',
    'Up': '\x1b[A',
    'C-l': '\x0c',
}
CLEAR_SCREEN_SEQUENCES = (
    '\x1b[H\x1b[2J',
    '\x1b[2J',
    '\x1b[3J',
    '\x0c',
)
COPILOT_READY_MARKER_GROUPS = (
    ('GitHub Copilot',),
    ('/ commands', '? help'),
)
COPILOT_PRIVACY_STRIP_MARKERS = tuple(
    marker for marker_group in COPILOT_READY_MARKER_GROUPS for marker in marker_group
)


@dataclass(frozen=True)
class ScreenshotTarget:
    name: str
    platform: str
    size: tuple[int, int]
    simulator_name: str | None = None
    android_size: str | None = None
    android_density: str | None = None


@dataclass(frozen=True)
class MonkeyMuxSessionRegistryEntry:
    session: str
    owner_pid: int | None = None
    owner_start_time: int | None = None
    registered_at: float | None = None

    def to_json(self) -> dict[str, object]:
        payload: dict[str, object] = {'session': self.session}
        if self.owner_pid is not None:
            payload['ownerPid'] = self.owner_pid
        if self.owner_start_time is not None:
            payload['ownerStartTime'] = self.owner_start_time
        if self.registered_at is not None:
            payload['registeredAt'] = self.registered_at
        return payload


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
    demo.reset_monkeymux()
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

    dart_defines = [
        f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PORT={demo.port}',
        f'--dart-define=STORE_SCREENSHOT_SSH_USERNAME={demo.username}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64={demo.private_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_B64={demo.host_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT={demo.host_key_fingerprint}',
        f'--dart-define=STORE_SCREENSHOT_MUX_SESSION={demo.mux_session}',
        f'--dart-define=STORE_SCREENSHOT_WORKSPACE_PATH={demo.demo_dir}',
        '--dart-define=STORE_SCREENSHOT_REDACT_IDENTITIES=true',
        '--dart-define=STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR=true',
        '--dart-define=STORE_SCREENSHOT_DISABLE_NOTIFICATIONS=true',
    ]
    command = [
        'flutter',
        'run',
        '--debug',
        '-d',
        device_id,
        '-t',
        'tool/store_screenshot_app.dart',
        *dart_defines,
    ]
    if target.platform in ('android', 'ios'):
        command.extend(['--flavor', 'production'])
    if target.platform == 'android':
        apk_path = _build_android_screenshot_apk(env, dart_defines)
        command = [
            'flutter',
            'run',
            '-d',
            device_id,
            '--use-application-binary',
            str(apk_path),
            '--no-pub',
        ]

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
    failure: str | None = None
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
            if ERROR_MARKER in line:
                failure = line.split(ERROR_MARKER, 1)[1].strip()
                break
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

    if failure is not None:
        raise RuntimeError(f'{target.name} run failed in the app: {failure}')

    if not saw_done:
        if process.returncode not in (0, None):
            raise subprocess.CalledProcessError(process.returncode, command)
        raise RuntimeError(f'{target.name} run ended before all screenshots were captured')


def _build_android_screenshot_apk(
    env: dict[str, str],
    dart_defines: list[str],
) -> Path:
    command = [
        'flutter',
        'build',
        'apk',
        '--debug',
        '--flavor',
        'production',
        '-t',
        'tool/store_screenshot_app.dart',
        '--no-pub',
        *dart_defines,
    ]
    subprocess.run(command, cwd=ROOT, env=env, check=True)
    apk_path = ROOT / 'build/app/outputs/flutter-apk/app-production-debug.apk'
    if not apk_path.exists():
        raise RuntimeError(f'Android screenshot APK was not produced: {apk_path}')
    return apk_path


class StoreDemoEnvironment:
    def __init__(self) -> None:
        self._tmpdir = Path(tempfile.mkdtemp(prefix='monkeyssh-store-demo-'))
        self.username = getpass.getuser()
        self.port = _free_local_port()
        self.mux_session = f'monkeyssh-store-{os.getpid()}'
        self.demo_dir = Path('/tmp') / self.mux_session
        self._process: subprocess.Popen[str] | None = None
        self._monkeymux = self._extract_monkeymux()
        self._monkeymux_env = self._build_monkeymux_env()
        self._monkeymux_process: subprocess.Popen[str] | None = None
        self._monkeymux_control: _MonkeyMuxControl | None = None
        self._owned_monkeymux_process_groups: set[int] = set()
        self._window_ids: dict[str, str] = {}
        self._copilot = shutil.which('copilot')
        if self._copilot is None:
            raise RuntimeError('GitHub Copilot CLI is required for the first store screenshot.')
        self._claude = shutil.which('claude')
        if self._claude is None:
            raise RuntimeError('Claude Code CLI is required for the Claude store screenshot.')
        self._opencode = shutil.which('opencode')

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
        try:
            self._cleanup_registered_monkeymux_sessions()
            self._register_monkeymux_session()
            self._create_keys()
            self._start_sshd()
            self._setup_monkeymux()
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exc_type, exc, tb) -> None:
        self._teardown_monkeymux(unregister=True)
        self._stop_sshd()
        self._remove_demo_dir()
        shutil.rmtree(self._tmpdir, ignore_errors=True)

    def reset_monkeymux(self) -> None:
        self._monkeymux_select('copilot')

    def _extract_monkeymux(self) -> Path:
        manifest = json.loads((ROOT / 'assets/monkeymux/manifest.json').read_text())
        platform_key = _monkeymux_platform_key()
        entry = next(
            (
                candidate
                for candidate in manifest.get('entries', [])
                if candidate.get('platform') == platform_key
            ),
            None,
        )
        if entry is None:
            raise RuntimeError(f'MonkeyMux is not bundled for {platform_key}.')

        asset_path = ROOT / entry['asset']
        asset_bytes = asset_path.read_bytes()
        encoding = entry.get('encoding')
        if encoding == 'gzip':
            binary_bytes = gzip.decompress(asset_bytes)
        elif encoding in (None, '', 'none'):
            binary_bytes = asset_bytes
        else:
            raise RuntimeError(f'Unsupported MonkeyMux asset encoding: {encoding}')

        expected_size = entry.get('size')
        if expected_size is not None and len(binary_bytes) != expected_size:
            raise RuntimeError(f'Bundled MonkeyMux size mismatch for {platform_key}.')
        expected_sha = entry.get('sha256')
        actual_sha = hashlib.sha256(binary_bytes).hexdigest()
        if expected_sha and actual_sha != expected_sha:
            raise RuntimeError(f'Bundled MonkeyMux checksum mismatch for {platform_key}.')

        executable = self._tmpdir / 'monkeymux'
        executable.write_bytes(binary_bytes)
        os.chmod(executable, 0o700)
        self._stage_bundled_monkeymux_install(
            manifest.get('version'),
            platform_key,
            binary_bytes,
        )
        return executable

    def _stage_bundled_monkeymux_install(
        self,
        version: str | None,
        platform_key: str,
        binary_bytes: bytes,
    ) -> None:
        # The app installs the bundled helper into the remote home directory and
        # asks the user to confirm first. The screenshot flow cannot answer that
        # prompt, so pre-stage the exact bundled binary where the installer looks
        # for it; the version check then reuses it instead of prompting.
        if not version:
            raise RuntimeError('Bundled MonkeyMux manifest is missing a version.')
        install_dir = (
            Path.home() / '.monkeyssh/bin/monkeymux' / version / platform_key
        )
        install_dir.mkdir(parents=True, exist_ok=True)
        executable = install_dir / 'monkeymux'
        if (
            not executable.exists()
            or hashlib.sha256(executable.read_bytes()).hexdigest()
            != hashlib.sha256(binary_bytes).hexdigest()
        ):
            executable.write_bytes(binary_bytes)
        os.chmod(executable, 0o700)

    def _build_monkeymux_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.pop('XDG_RUNTIME_DIR', None)
        env.setdefault('TERM', 'xterm-256color')
        return env

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

    def _setup_monkeymux(self) -> None:
        self._prepare_demo_dir()
        self._teardown_monkeymux()
        self._write_pane_script(
            'copilot',
            f"""
            exec env COPILOT_ALLOW_ALL=0 \\
              {self._shell_quote(self._copilot)} \\
              --no-remote \\
              --log-level default \\
              --secret-env-vars=USER,EMAIL,GITHUB_TOKEN,GH_TOKEN,ANTHROPIC_API_KEY \\
              --name 'Mobile Copilot Workspace'
            """,
        )
        self._write_pane_script(
            'claude',
            f"""
            exec env \\
              PATH={self._shell_quote(os.environ.get('PATH', ''))} \\
              TERM=xterm-256color \\
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
            printf 'Keep long-running coding sessions alive in MonkeyMux.\\n'
            """,
        )
        opencode_home = self._tmpdir / 'opencode-home'
        (opencode_home / '.config/opencode').mkdir(parents=True, exist_ok=True)
        (opencode_home / '.config/opencode/tui.json').write_text('{"theme":"system"}\n')
        opencode_body = (
            f"""
            exec env \\
              HOME={self._shell_quote(str(opencode_home))} \\
              PATH={self._shell_quote(os.environ.get('PATH', ''))} \\
              TERM=xterm-256color \\
              {self._shell_quote(self._opencode)} \\
              --pure \\
              --log-level ERROR \\
              --prompt 'Inspect the release checklist image and keep this agent session ready.'
            """
            if self._opencode is not None
            else """
            clear
            printf 'OpenCode agent session ready\\n'
            printf 'Launch another coding assistant in its own remote window.\\n'
            """
        )
        self._write_pane_script('opencode', opencode_body)
        self._write_pane_script(
            'antigravity',
            """
            clear
            printf 'Antigravity agent session ready\\n'
            printf 'Use MonkeyMux to keep multiple agents running side by side.\\n'
            """,
        )
        self._start_monkeymux_windows()
        self._drive_copilot_start_screen()
        self._drive_claude_full_screen()
        self.reset_monkeymux()

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
                    '- Keep captures free of emails, usernames, hostnames, tokens, and private identifiers.',
                    '- Prefer concise checks that fit in a mobile terminal screenshot.',
                    '- Keep terminal output focused on SSH, MonkeyMux, agent, and store asset workflows.',
                    '',
                    'Windows:',
                    '1. copilot - GitHub Copilot CLI',
                    '2. gemini  - Gemini CLI workspace',
                    '3. claude  - Claude Code workspace',
                    '4. codex   - Codex CLI workspace',
                    '5. opencode - OpenCode CLI workspace',
                    '6. antigravity - Antigravity CLI workspace',
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
                    '- Confirm MonkeyMux reattach restores the same shell, panes, and scrollback.',
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
                    '| App Store | iPhone 6.9, iPad 13 | Copilot, hosts, snippets, MonkeyMux selector with all supported agent windows, SFTP, Claude Code |',
                    '| Google Play | Phone, 7-inch tablet, 10-inch tablet | Same scene order for production and private tracks |',
                    '',
                    'Validation checklist:',
                    '',
                    '- Capture from the normal MonkeySSH app, not a direct-mounted screen harness.',
                    '- Use a live SSH connection into this MonkeyMux workspace.',
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

    def _start_monkeymux_windows(self) -> None:
        self._monkeymux_process = subprocess.Popen(
            [
                str(self._monkeymux),
                'serve',
                '--session',
                self.mux_session,
                '--cwd',
                str(self.demo_dir),
                '--name',
                'copilot',
                '--command',
                str(self._tmpdir / 'copilot-pane.sh'),
            ],
            env=self._monkeymux_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,
        )
        self._monkeymux_control = self._open_monkeymux_control()
        self._refresh_monkeymux_windows()
        for window in ('gemini', 'claude', 'codex', 'opencode', 'antigravity'):
            response = self._monkeymux_request(
                {
                    'type': 'create_window',
                    'name': window,
                    'cwd': str(self.demo_dir),
                    'command': str(self._tmpdir / f'{window}-pane.sh'),
                }
            )
            snapshot = response.get('window')
            if isinstance(snapshot, dict) and isinstance(snapshot.get('id'), str):
                self._window_ids[window] = snapshot['id']
                self._remember_monkeymux_window_process_group(snapshot)
        self.reset_monkeymux()

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
        self._monkeymux_send_keys('copilot', 'Enter')
        time.sleep(8)
        self._ensure_copilot_streamer_mode()
        self._monkeymux_send_keys('copilot', 'C-l')
        time.sleep(2)
        self._wait_for_copilot_ready()
        self._assert_copilot_pane_streamer_safe()

    def _wait_for_copilot_ready(self) -> None:
        deadline = time.time() + 30
        text = ''
        while time.time() < deadline:
            text = self._capture_visible_pane('copilot')
            if _visible_text_contains_marker_group(
                text,
                COPILOT_READY_MARKER_GROUPS,
            ):
                return
            time.sleep(1)
        raise RuntimeError(
            'copilot pane did not show the Copilot prompt. '
            f'Last visible pane text:\n{text.strip()[-1000:]}',
        )

    def _drive_claude_full_screen(self) -> None:
        self._drive_claude_to_ready_prompt()
        self._monkeymux_send_keys('claude', 'C-l')
        time.sleep(2)
        self._wait_for_visible_text('claude', ['shortcuts'])
        time.sleep(3)
        self._assert_claude_pane_streamer_safe()

    def _drive_claude_to_ready_prompt(self) -> None:
        deadline = time.time() + 90
        while time.time() < deadline:
            text = self._capture_visible_pane('claude')
            if _visible_text_contains_marker(text, 'shortcuts') and (
                _visible_text_contains_marker(text, 'Claude Code')
                or _visible_text_contains_marker(text, 'Claude Code Workspace')
            ):
                return
            if _visible_text_contains_marker(text, 'Choose the text style'):
                self._monkeymux_send_keys('claude', 'Enter')
            elif _visible_text_contains_marker(text, 'Detected a custom API key'):
                self._monkeymux_send_keys('claude', 'Up', 'Enter')
            elif _visible_text_contains_marker(text, 'Yes, I trust this folder'):
                self._monkeymux_send_keys('claude', 'Enter')
            elif _visible_text_contains_marker(text, 'Press Ente'):
                self._monkeymux_send_keys('claude', 'Enter')
            time.sleep(1)
        raise RuntimeError('claude pane did not show the Claude Code prompt.')

    def _ensure_copilot_streamer_mode(self) -> None:
        self._wait_for_copilot_ready()
        self._monkeymux_send_literal('copilot', '/streamer')
        self._monkeymux_send_keys('copilot', 'Enter')
        time.sleep(4)
        text = self._capture_visible_pane('copilot')
        if _visible_text_contains_marker(text, 'Streamer mode enabled.'):
            return
        if _visible_text_contains_marker(text, 'Streamer mode disabled.'):
            self._monkeymux_send_literal('copilot', '/streamer')
            self._monkeymux_send_keys('copilot', 'Enter')
            time.sleep(4)
            text = self._capture_visible_pane('copilot')
            if _visible_text_contains_marker(text, 'Streamer mode enabled.'):
                return
        self._assert_copilot_pane_streamer_safe()

    def _wait_for_visible_text(self, window: str, markers: list[str]) -> None:
        deadline = time.time() + 30
        while time.time() < deadline:
            text = self._capture_visible_pane(window)
            if all(_visible_text_contains_marker(text, marker) for marker in markers):
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
        if window == 'copilot':
            text = _text_after_last_visible_markers(
                text,
                COPILOT_PRIVACY_STRIP_MARKERS,
            )
        elif window == 'claude':
            text = _text_after_last_visible_marker(text, 'Claude Code')
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
        self._monkeymux_select(window)
        output = self._capture_monkeymux_attach_replay()
        return _strip_terminal_output(output.decode(errors='ignore'))

    def _monkeymux_send_keys(self, window: str, *keys: str) -> None:
        try:
            payload = ''.join(KEY_BYTES[key] for key in keys)
        except KeyError as error:
            raise RuntimeError(f'Unsupported MonkeyMux key: {error.args[0]}') from error
        self._monkeymux_inject(window, payload)

    def _monkeymux_send_literal(self, window: str, text: str) -> None:
        self._monkeymux_inject(window, text)

    def _monkeymux_inject(self, window: str, data: str) -> None:
        window_id = self._window_id(window)
        self._monkeymux_request(
            {'type': 'inject_input', 'windowId': window_id, 'data': data}
        )

    def _monkeymux_select(self, window: str) -> None:
        self._monkeymux_request(
            {'type': 'select_window', 'windowId': self._window_id(window)}
        )

    def _window_id(self, window: str) -> str:
        window_id = self._window_ids.get(window)
        if window_id is not None:
            return window_id
        self._refresh_monkeymux_windows()
        window_id = self._window_ids.get(window)
        if window_id is None:
            raise RuntimeError(f'MonkeyMux window not found: {window}')
        return window_id

    def _refresh_monkeymux_windows(self) -> None:
        response = self._monkeymux_request({'type': 'list_windows'})
        windows = response.get('windows')
        if not isinstance(windows, list):
            raise RuntimeError('MonkeyMux did not return a window list.')
        self._window_ids = {
            window['name']: window['id']
            for window in windows
            if isinstance(window, dict)
            and isinstance(window.get('name'), str)
            and isinstance(window.get('id'), str)
        }
        for window in windows:
            if isinstance(window, dict):
                self._remember_monkeymux_window_process_group(window)

    def _remember_monkeymux_window_process_group(
        self,
        window: dict[str, object],
    ) -> None:
        pane_pid = window.get('panePid')
        if isinstance(pane_pid, int) and pane_pid > 1:
            self._owned_monkeymux_process_groups.add(pane_pid)

    def _open_monkeymux_control(self) -> _MonkeyMuxControl:
        deadline = time.time() + 10
        last_error: Exception | None = None
        while time.time() < deadline:
            if (
                self._monkeymux_process is not None
                and self._monkeymux_process.poll() is not None
            ):
                raise RuntimeError('MonkeyMux server exited before accepting control.')
            try:
                return _MonkeyMuxControl(
                    self._monkeymux,
                    self.mux_session,
                    self._monkeymux_env,
                )
            except RuntimeError as error:
                last_error = error
                time.sleep(0.2)
        raise RuntimeError(
            f'Timed out waiting for MonkeyMux control: {last_error}'
        ) from last_error

    def _monkeymux_request(self, message: dict[str, object]) -> dict[str, object]:
        if self._monkeymux_control is None:
            raise RuntimeError('MonkeyMux control is not connected.')
        return self._monkeymux_control.request(message)

    def _capture_monkeymux_attach_replay(self) -> bytes:
        master_fd = -1
        slave_fd = -1
        process: subprocess.Popen[str] | None = None
        try:
            master_fd, slave_fd = pty.openpty()
            _set_pty_size(slave_fd, rows=40, columns=120)
            process = subprocess.Popen(
                [
                    str(self._monkeymux),
                    'attach',
                    '--update-policy',
                    'never',
                    self.mux_session,
                ],
                env=self._monkeymux_env,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
                text=False,
            )
            os.close(slave_fd)
            slave_fd = -1
            flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
            fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

            chunks: list[bytes] = []
            deadline = time.time() + 2.0
            last_data_at: float | None = None
            while time.time() < deadline:
                timeout = min(0.2, max(deadline - time.time(), 0))
                readable, _, _ = select.select([master_fd], [], [], timeout)
                if not readable:
                    if last_data_at is not None and time.time() - last_data_at > 0.25:
                        break
                    continue
                try:
                    chunk = os.read(master_fd, 65536)
                except BlockingIOError:
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
                last_data_at = time.time()
            return b''.join(chunks)
        finally:
            if slave_fd >= 0:
                os.close(slave_fd)
            if master_fd >= 0:
                os.close(master_fd)
            if process is not None:
                _terminate_process(process, timeout=5)

    @staticmethod
    def _shell_quote(value: str) -> str:
        return "'" + value.replace("'", "'\"'\"'") + "'"

    def _teardown_monkeymux(self, *, unregister: bool = False) -> None:
        self._collect_monkeymux_window_process_groups()
        control = self._monkeymux_control
        self._monkeymux_control = None
        if control is not None:
            try:
                control.request({'type': 'shutdown'}, timeout=2)
            except RuntimeError as error:
                _warn_cleanup(f'MonkeyMux shutdown request failed: {error}')
            control.close()
        if self._monkeymux_process is not None:
            _terminate_process(
                self._monkeymux_process,
                timeout=5,
                process_group=True,
            )
            self._monkeymux_process = None
        _terminate_process_groups(self._owned_monkeymux_process_groups)
        self._owned_monkeymux_process_groups.clear()
        self._run_monkeymux_gc()
        if unregister:
            self._unregister_monkeymux_session()

    def _collect_monkeymux_window_process_groups(self) -> None:
        control = self._monkeymux_control
        if control is None:
            return
        try:
            response = control.request({'type': 'list_windows'}, timeout=2)
        except RuntimeError as error:
            _warn_cleanup(f'Could not list MonkeyMux windows for cleanup: {error}')
            return
        windows = response.get('windows')
        if not isinstance(windows, list):
            return
        for window in windows:
            if isinstance(window, dict):
                self._remember_monkeymux_window_process_group(window)

    def _cleanup_registered_monkeymux_sessions(self) -> None:
        def cleanup(
            entries: list[MonkeyMuxSessionRegistryEntry],
        ) -> list[MonkeyMuxSessionRegistryEntry]:
            remaining: list[MonkeyMuxSessionRegistryEntry] = []
            for entry in entries:
                session = entry.session
                is_stale_screenshot_session = session.startswith(
                    'monkeyssh-store-',
                ) and not _is_registry_entry_owner_alive(entry)
                if session == self.mux_session or is_stale_screenshot_session:
                    cleaned = _shutdown_monkeymux_session(
                        self._monkeymux,
                        session,
                        self._monkeymux_env,
                    )
                    if not cleaned:
                        remaining.append(entry)
                    continue
                remaining.append(entry)
            return remaining

        _update_registered_monkeymux_sessions(cleanup)
        self._run_monkeymux_gc()

    def _register_monkeymux_session(self) -> None:
        entry = MonkeyMuxSessionRegistryEntry(
            session=self.mux_session,
            owner_pid=os.getpid(),
            owner_start_time=_process_start_time(os.getpid()),
            registered_at=time.time(),
        )

        def register(
            entries: list[MonkeyMuxSessionRegistryEntry],
        ) -> list[MonkeyMuxSessionRegistryEntry]:
            return [
                existing
                for existing in entries
                if existing.session != self.mux_session
            ] + [entry]

        _update_registered_monkeymux_sessions(register)

    def _unregister_monkeymux_session(self) -> None:
        def unregister(
            entries: list[MonkeyMuxSessionRegistryEntry],
        ) -> list[MonkeyMuxSessionRegistryEntry]:
            return [
                entry
                for entry in entries
                if entry.session != self.mux_session
            ]

        _update_registered_monkeymux_sessions(unregister)

    def _run_monkeymux_gc(self) -> None:
        result = subprocess.run(
            [str(self._monkeymux), 'gc'],
            env=self._monkeymux_env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            _warn_cleanup(f'MonkeyMux gc failed: {result.stderr.strip()}')

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


class _MonkeyMuxControl:
    def __init__(self, executable: Path, session: str, env: dict[str, str]) -> None:
        self._process = subprocess.Popen(
            [str(executable), 'control', '--json', session],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._responses: queue.Queue[dict[str, object] | Exception] = queue.Queue()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._counter = 0
        self._reader.start()
        self._wait_for_hello()

    def request(
        self,
        message: dict[str, object],
        *,
        timeout: float = 10,
    ) -> dict[str, object]:
        if self._process.stdin is None:
            raise RuntimeError('MonkeyMux control stdin is unavailable.')
        if self._process.poll() is not None:
            raise RuntimeError('MonkeyMux control process exited.')
        self._counter += 1
        request_id = f'capture-{os.getpid()}-{self._counter}'
        payload = {'id': request_id, **message}
        self._process.stdin.write(json.dumps(payload) + '\n')
        self._process.stdin.flush()

        deadline = time.time() + timeout
        while time.time() < deadline:
            response = self._read_response(max(deadline - time.time(), 0.1))
            if response.get('id') != request_id:
                continue
            if response.get('status') == 'error':
                raise RuntimeError(
                    str(response.get('error') or 'MonkeyMux control request failed.')
                )
            return response
        raise RuntimeError(f'MonkeyMux control request timed out: {message.get("type")}')

    def close(self) -> None:
        if self._process.stdin is not None:
            self._process.stdin.close()
        _terminate_process(self._process, timeout=2)
        self._reader.join(timeout=1)

    def _wait_for_hello(self) -> None:
        deadline = time.time() + 2
        while time.time() < deadline:
            response = self._read_response(max(deadline - time.time(), 0.1))
            if response.get('type') == 'hello' and response.get('status') == 'ok':
                return
        raise RuntimeError('MonkeyMux control did not send hello.')

    def _read_response(self, timeout: float) -> dict[str, object]:
        try:
            response = self._responses.get(timeout=timeout)
        except queue.Empty as error:
            if self._process.poll() is not None:
                raise RuntimeError('MonkeyMux control process exited.') from error
            raise RuntimeError('Timed out reading MonkeyMux control output.') from error
        if isinstance(response, Exception):
            raise response
        return response

    def _read_loop(self) -> None:
        if self._process.stdout is None:
            self._responses.put(RuntimeError('MonkeyMux control stdout is unavailable.'))
            return
        for line in self._process.stdout:
            try:
                decoded = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(decoded, dict):
                self._responses.put(decoded)
        self._responses.put(RuntimeError('MonkeyMux control closed stdout.'))


def _monkeymux_platform_key() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    os_name = {
        'darwin': 'darwin',
        'linux': 'linux',
    }.get(system)
    arch = {
        'amd64': 'amd64',
        'x86_64': 'amd64',
        'arm64': 'arm64',
        'aarch64': 'arm64',
    }.get(machine)
    if os_name is None or arch is None:
        raise RuntimeError(f'MonkeyMux is not bundled for {system}-{machine}.')
    return f'{os_name}-{arch}'


def _set_pty_size(fd: int, *, rows: int, columns: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))


def _strip_terminal_output(text: str) -> str:
    text = _latest_visible_screen_text(text)
    stripped = ANSI_ESCAPE_PATTERN.sub('', text)
    stripped = stripped.replace('\r\n', '\n').replace('\r', '\n')
    return ''.join(
        character
        if character in ('\n', '\t') or ord(character) >= 32
        else ' '
        for character in stripped
    )


def _latest_visible_screen_text(text: str) -> str:
    latest_end = -1
    for sequence in CLEAR_SCREEN_SEQUENCES:
        index = text.rfind(sequence)
        if index >= 0:
            latest_end = max(latest_end, index + len(sequence))
    return text[latest_end:] if latest_end >= 0 else text


def _visible_text_contains_marker(text: str, marker: str) -> bool:
    if marker in text:
        return True
    compact_text = re.sub(r'\s+', '', text)
    compact_marker = re.sub(r'\s+', '', marker)
    return compact_marker in compact_text


def _visible_text_contains_marker_group(
    text: str,
    marker_groups: tuple[tuple[str, ...], ...],
) -> bool:
    return any(
        all(_visible_text_contains_marker(text, marker) for marker in marker_group)
        for marker_group in marker_groups
    )


def _text_after_last_visible_marker(text: str, marker: str) -> str:
    index = text.rfind(marker)
    if index >= 0:
        return text[index:]
    compact_text = re.sub(r'\s+', '', text)
    compact_marker = re.sub(r'\s+', '', marker)
    compact_index = compact_text.rfind(compact_marker)
    if compact_index >= 0:
        return compact_text[compact_index:]
    return text


def _text_after_last_visible_markers(text: str, markers: tuple[str, ...]) -> str:
    matches = [
        candidate
        for marker in markers
        if (candidate := _text_after_last_visible_marker(text, marker)) != text
    ]
    if not matches:
        return text
    return min(matches, key=len)


def _terminate_process(
    process: subprocess.Popen,
    *,
    timeout: float,
    process_group: bool = False,
) -> None:
    if process.poll() is not None:
        return
    _signal_process(process, signal.SIGTERM, process_group=process_group)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _signal_process(process, signal.SIGKILL, process_group=process_group)
        process.wait(timeout=timeout)


def _signal_process(
    process: subprocess.Popen,
    sig: signal.Signals,
    *,
    process_group: bool,
) -> None:
    if not process_group:
        process.send_signal(sig)
        return
    try:
        process_group_id = os.getpgid(process.pid)
    except ProcessLookupError:
        return
    if process_group_id == os.getpgrp():
        process.send_signal(sig)
        return
    try:
        os.killpg(process_group_id, sig)
    except ProcessLookupError:
        return


def _shutdown_monkeymux_session(
    executable: Path,
    session: str,
    env: dict[str, str],
) -> bool:
    control: _MonkeyMuxControl | None = None
    process_groups: set[int] = set()
    try:
        control = _MonkeyMuxControl(executable, session, env)
    except RuntimeError:
        return True
    try:
        response = control.request({'type': 'list_windows'}, timeout=2)
        windows = response.get('windows')
        if isinstance(windows, list):
            process_groups = _monkeymux_window_process_groups(windows)
        control.request({'type': 'shutdown'}, timeout=2)
    except RuntimeError as error:
        _warn_cleanup(f'Could not shut down stale MonkeyMux session {session}: {error}')
        _terminate_process_groups(process_groups)
        return False
    finally:
        if control is not None:
            control.close()

    if not _wait_for_monkeymux_session_exit(executable, session, env, timeout=5):
        _warn_cleanup(f'MonkeyMux session {session} did not exit after shutdown.')
        _terminate_process_groups(process_groups)
        return _wait_for_monkeymux_session_exit(executable, session, env, timeout=2)
    _terminate_process_groups(process_groups)
    return True


def _wait_for_monkeymux_session_exit(
    executable: Path,
    session: str,
    env: dict[str, str],
    *,
    timeout: float,
) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            control = _MonkeyMuxControl(executable, session, env)
        except RuntimeError:
            return True
        control.close()
        time.sleep(0.1)
    return False


def _monkeymux_window_process_groups(windows: list[object]) -> set[int]:
    process_groups: set[int] = set()
    for window in windows:
        if not isinstance(window, dict):
            continue
        pane_pid = window.get('panePid')
        if isinstance(pane_pid, int) and pane_pid > 1:
            process_groups.add(pane_pid)
    return process_groups


def _terminate_process_groups(process_groups: set[int]) -> None:
    live_groups = set(process_groups)
    if not live_groups:
        return
    if _wait_for_process_groups_exit(live_groups, timeout=2):
        return
    for sig, timeout in (
        (signal.SIGTERM, 2),
        (signal.SIGKILL, 2),
    ):
        for process_group_id in list(live_groups):
            _signal_process_group(process_group_id, sig)
        if _wait_for_process_groups_exit(live_groups, timeout=timeout):
            return
    _warn_cleanup(
        'Some MonkeyMux window process groups did not exit: '
        f'{", ".join(str(pid) for pid in sorted(live_groups))}',
    )


def _wait_for_process_groups_exit(process_groups: set[int], *, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        live_process_groups = {
            pid for pid in process_groups if _is_process_group_running(pid)
        }
        process_groups.intersection_update(live_process_groups)
        if not process_groups:
            return True
        time.sleep(0.1)
    live_process_groups = {
        pid for pid in process_groups if _is_process_group_running(pid)
    }
    process_groups.intersection_update(live_process_groups)
    return not process_groups


def _is_process_group_running(process_group_id: int) -> bool:
    if process_group_id <= 1 or process_group_id == os.getpgrp():
        return False
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal_process_group(process_group_id: int, sig: signal.Signals) -> None:
    if process_group_id <= 1:
        return
    if process_group_id == os.getpgrp():
        _warn_cleanup(f'Refusing to signal current process group {process_group_id}.')
        return
    try:
        os.killpg(process_group_id, sig)
    except ProcessLookupError:
        return
    except PermissionError as error:
        _warn_cleanup(f'Could not signal process group {process_group_id}: {error}')


def _monkeymux_session_registry_path() -> Path:
    state_home = os.environ.get('XDG_STATE_HOME')
    root = Path(state_home) if state_home else Path.home() / '.local/state'
    return root / 'monkeyssh' / 'store-screenshots' / 'monkeymux-sessions.json'


def _monkeymux_session_registry_lock_path() -> Path:
    registry_path = _monkeymux_session_registry_path()
    return registry_path.with_name(f'{registry_path.name}.lock')


def _update_registered_monkeymux_sessions(update):
    registry_path = _monkeymux_session_registry_path()
    lock_path = _monkeymux_session_registry_lock_path()
    try:
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open('a+') as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            entries = _read_registered_monkeymux_sessions_unlocked(registry_path)
            updated_entries = update(entries)
            _write_registered_monkeymux_sessions_unlocked(
                registry_path,
                updated_entries,
            )
            return updated_entries
    except OSError as error:
        _warn_cleanup(f'Could not update MonkeyMux session registry: {error}')
        return []


def _read_registered_monkeymux_sessions_unlocked(
    path: Path,
) -> list[MonkeyMuxSessionRegistryEntry]:
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        _warn_cleanup(f'Could not read MonkeyMux session registry: {error}')
        return []
    if not isinstance(payload, list):
        return []
    entries: list[MonkeyMuxSessionRegistryEntry] = []
    for item in payload:
        entry = _decode_registry_entry(item)
        if entry is not None:
            entries.append(entry)
    return entries


def _decode_registry_entry(item: object) -> MonkeyMuxSessionRegistryEntry | None:
    if isinstance(item, str) and item.strip():
        return MonkeyMuxSessionRegistryEntry(session=item.strip())
    if not isinstance(item, dict):
        return None
    session = item.get('session')
    if not isinstance(session, str) or not session.strip():
        return None
    return MonkeyMuxSessionRegistryEntry(
        session=session.strip(),
        owner_pid=_int_or_none(item.get('ownerPid')),
        owner_start_time=_int_or_none(item.get('ownerStartTime')),
        registered_at=_float_or_none(item.get('registeredAt')),
    )


def _write_registered_monkeymux_sessions_unlocked(
    path: Path,
    entries: list[MonkeyMuxSessionRegistryEntry],
) -> None:
    unique_entries = _unique_registry_entries(entries)
    if not unique_entries:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return

    payload = [entry.to_json() for entry in unique_entries]
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            'w',
            dir=path.parent,
            prefix=f'{path.name}.',
            suffix='.tmp',
            delete=False,
        ) as temp_file:
            temp_path = Path(temp_file.name)
            json.dump(payload, temp_file, indent=2)
            temp_file.write('\n')
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def _unique_registry_entries(
    entries: list[MonkeyMuxSessionRegistryEntry],
) -> list[MonkeyMuxSessionRegistryEntry]:
    unique_by_session: dict[str, MonkeyMuxSessionRegistryEntry] = {}
    for entry in entries:
        unique_by_session[entry.session] = entry
    return [
        unique_by_session[session]
        for session in sorted(unique_by_session)
    ]


def _is_registry_entry_owner_alive(entry: MonkeyMuxSessionRegistryEntry) -> bool:
    owner_pid = entry.owner_pid
    if owner_pid is None or owner_pid <= 1:
        return False
    try:
        os.kill(owner_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    if entry.owner_start_time is None:
        return True
    current_start_time = _process_start_time(owner_pid)
    if current_start_time is None:
        return True
    return current_start_time == entry.owner_start_time


def _process_start_time(pid: int) -> int | None:
    try:
        result = subprocess.run(
            ['ps', '-o', 'lstart=', '-p', str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
            timeout=1,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    if not value:
        return None
    try:
        return int(time.mktime(time.strptime(value, '%a %b %d %H:%M:%S %Y')))
    except ValueError:
        return None


def _int_or_none(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _float_or_none(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (float, int)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _warn_cleanup(message: str) -> None:
    print(f'warning: {message}', file=sys.stderr)


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
            ['xcrun', 'simctl', 'terminate', device_id, bundle_id],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
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
