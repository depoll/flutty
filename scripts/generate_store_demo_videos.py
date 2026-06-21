#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import generate_store_screenshots as store_screenshots

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / 'build/store-demo-videos'
DEFAULT_SCENE_HOLD_MS = 1600
ANDROID_RECORDING_BIT_RATE = 8_000_000
IOS_APP_PREVIEW_NAME = 'iphone_67_1.mov'


@dataclass(frozen=True)
class DemoVideoTarget:
    name: str
    screenshot_target: store_screenshots.ScreenshotTarget
    output_name: str
    ios_app_preview_name: str | None = None


TARGETS = {
    'ios': DemoVideoTarget(
        name='ios',
        screenshot_target=store_screenshots.TARGETS['ios_phone'],
        output_name='monkeyssh-ios-demo.mov',
        ios_app_preview_name=IOS_APP_PREVIEW_NAME,
    ),
    'android': DemoVideoTarget(
        name='android',
        screenshot_target=store_screenshots.TARGETS['android_phone'],
        output_name='monkeyssh-android-demo.mp4',
    ),
}


def main() -> None:
    store_screenshots._prefer_stable_xcode()
    args = _parse_args()
    targets = _targets_for_platform(args.platform)
    output_dir = Path(args.output_dir).expanduser().resolve()

    with store_screenshots.StoreDemoEnvironment() as demo:
        for target in targets:
            _run_target(
                target=target,
                demo=demo,
                output_dir=output_dir,
                scene_hold_ms=args.scene_hold_ms,
                write_ios_app_preview=args.ios_app_preview,
            )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Record short real-device MonkeySSH product demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which demo video to record.',
    )
    parser.add_argument(
        '--output-dir',
        default=str(DEFAULT_OUTPUT_DIR),
        help='Directory for generated videos. Defaults to build/store-demo-videos.',
    )
    parser.add_argument(
        '--scene-hold-ms',
        type=int,
        default=DEFAULT_SCENE_HOLD_MS,
        help='Milliseconds to hold each settled scene while recording.',
    )
    parser.add_argument(
        '--ios-app-preview',
        action='store_true',
        help=(
            'Also copy the iOS video into ios/fastlane/app-previews/en-US '
            f'as {IOS_APP_PREVIEW_NAME}.'
        ),
    )
    return parser.parse_args()


def _targets_for_platform(platform: str) -> list[DemoVideoTarget]:
    if platform == 'ios':
        return [TARGETS['ios']]
    if platform == 'android':
        return [TARGETS['android']]
    return [TARGETS['ios'], TARGETS['android']]


def _run_target(
    *,
    target: DemoVideoTarget,
    demo: store_screenshots.StoreDemoEnvironment,
    output_dir: Path,
    scene_hold_ms: int,
    write_ios_app_preview: bool,
) -> None:
    print(f'Recording {target.name} demo video...')
    demo.reset_monkeymux()
    screenshot_target = target.screenshot_target
    if screenshot_target.platform == 'ios':
        device_id = store_screenshots._boot_ios_simulator(
            store_screenshots._ios_simulator_name(screenshot_target),
        )
        store_screenshots._reset_ios_app_state(device_id)
        restore_android = None
    else:
        device_id = store_screenshots._android_device_id()
        restore_android = store_screenshots._configure_android_display(
            screenshot_target,
            device_id,
        )

    output_path = output_dir / target.name / target.output_name
    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        _run_flutter_recording(
            target=screenshot_target,
            device_id=device_id,
            demo=demo,
            output_path=output_path,
            scene_hold_ms=scene_hold_ms,
        )
    finally:
        if restore_android is not None:
            restore_android()

    if (
        write_ios_app_preview
        and target.ios_app_preview_name is not None
        and screenshot_target.platform == 'ios'
    ):
        app_preview_path = (
            ROOT
            / 'ios/fastlane/app-previews/en-US'
            / target.ios_app_preview_name
        )
        app_preview_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(output_path, app_preview_path)
        print(f'Wrote {app_preview_path.relative_to(ROOT)}')


def _run_flutter_recording(
    *,
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    demo: store_screenshots.StoreDemoEnvironment,
    output_path: Path,
    scene_hold_ms: int,
) -> None:
    env = os.environ.copy()
    java_home = store_screenshots._java_home_17()
    if java_home:
        env['JAVA_HOME'] = java_home

    dart_defines = [
        f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PORT={demo.port}',
        f'--dart-define=STORE_SCREENSHOT_SSH_USERNAME={demo.username}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64={demo.private_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_B64={demo.host_key_b64}',
        (
            '--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT='
            f'{demo.host_key_fingerprint}'
        ),
        f'--dart-define=STORE_SCREENSHOT_MUX_SESSION={demo.mux_session}',
        f'--dart-define=STORE_SCREENSHOT_WORKSPACE_PATH={demo.demo_dir}',
        '--dart-define=STORE_SCREENSHOT_REDACT_IDENTITIES=true',
        '--dart-define=STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR=true',
        '--dart-define=STORE_SCREENSHOT_DISABLE_NOTIFICATIONS=true',
        f'--dart-define=STORE_SCREENSHOT_SCENE_HOLD_MS={scene_hold_ms}',
    ]
    command = _flutter_command(target, device_id, env, dart_defines)
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

    recorder: _NativeScreenRecorder | None = None
    saw_done = False
    try:
        for raw_line in process.stdout:
            print(raw_line, end='')
            line = raw_line.strip()
            if store_screenshots.READY_MARKER in line and recorder is None:
                pending_recorder = _recorder_for_target(target, device_id, output_path)
                pending_recorder.start()
                recorder = pending_recorder
            if store_screenshots.DONE_MARKER in line:
                saw_done = True
                break
    finally:
        if recorder is not None:
            recorder.stop()
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
        raise RuntimeError(f'{target.name} run ended before the video was complete')
    if recorder is None:
        raise RuntimeError(f'{target.name} run ended before recording started')
    if output_path.stat().st_size < 500_000:
        raise RuntimeError(f'{output_path} is too small to be a real screen recording')

    print(f'Wrote {output_path.relative_to(ROOT)}')


def _flutter_command(
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    env: dict[str, str],
    dart_defines: list[str],
) -> list[str]:
    if target.platform == 'android':
        apk_path = store_screenshots._build_android_screenshot_apk(env, dart_defines)
        return [
            'flutter',
            'run',
            '-d',
            device_id,
            '--use-application-binary',
            str(apk_path),
            '--no-pub',
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
    if target.platform == 'ios':
        command.extend(['--flavor', 'production'])
    return command


def _recorder_for_target(
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    output_path: Path,
) -> _NativeScreenRecorder:
    if target.platform == 'ios':
        return _IosSimulatorRecorder(device_id=device_id, output_path=output_path)
    return _AndroidScreenRecorder(
        device_id=device_id,
        output_path=output_path,
        size=target.size,
    )


class _NativeScreenRecorder:
    def start(self) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class _IosSimulatorRecorder(_NativeScreenRecorder):
    def __init__(self, *, device_id: str, output_path: Path) -> None:
        self._device_id = device_id
        self._output_path = output_path
        self._process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        self._process = subprocess.Popen(
            [
                'xcrun',
                'simctl',
                'io',
                self._device_id,
                'recordVideo',
                '--codec=h264',
                '--force',
                str(self._output_path),
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        time.sleep(0.5)
        if self._process.poll() is not None:
            stderr = self._process.stderr.read() if self._process.stderr else ''
            raise RuntimeError(f'iOS screen recording failed to start: {stderr}')

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if process.stderr is not None:
            process.stderr.close()


class _AndroidScreenRecorder(_NativeScreenRecorder):
    def __init__(
        self,
        *,
        device_id: str,
        output_path: Path,
        size: tuple[int, int],
    ) -> None:
        self._adb = store_screenshots._adb_path()
        self._device_id = device_id
        self._output_path = output_path
        self._size = size
        self._process: subprocess.Popen[str] | None = None
        suffix = f'{os.getpid()}-{int(time.time())}'
        self._remote_path = f'/sdcard/monkeyssh-store-demo-{suffix}.mp4'
        self._pid_path = f'/data/local/tmp/monkeyssh-store-demo-{suffix}.pid'
        self._remote_pid: int | None = None

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        width, height = self._size
        remote_command = (
            f'echo $$ > {self._pid_path}; '
            'exec screenrecord '
            f'--bit-rate {ANDROID_RECORDING_BIT_RATE} '
            f'--size {width}x{height} '
            f'{self._remote_path}'
        )
        self._process = subprocess.Popen(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                remote_command,
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self._remote_pid = self._wait_for_remote_pid()

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is not None and process.poll() is None:
            if self._remote_pid is not None:
                subprocess.run(
                    [
                        str(self._adb),
                        '-s',
                        self._device_id,
                        'shell',
                        'kill',
                        '-2',
                        str(self._remote_pid),
                    ],
                    cwd=ROOT,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'pull',
                self._remote_path,
                str(self._output_path),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                'rm',
                '-f',
                self._remote_path,
                self._pid_path,
            ],
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _wait_for_remote_pid(self) -> int:
        deadline = time.time() + 10
        while time.time() < deadline:
            process = self._process
            if process is not None and process.poll() is not None:
                raise RuntimeError('Android screenrecord exited before recording started')
            result = subprocess.run(
                [
                    str(self._adb),
                    '-s',
                    self._device_id,
                    'shell',
                    'cat',
                    self._pid_path,
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value.isdigit():
                    return int(value)
            time.sleep(0.2)
        raise RuntimeError('Timed out waiting for Android screenrecord to start')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'error: {error}', file=sys.stderr)
        raise
