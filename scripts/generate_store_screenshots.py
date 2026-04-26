#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ADB = Path.home() / 'Library/Android/sdk/platform-tools/adb'
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
        size=(1080, 1920),
        android_size='1080x1920',
        android_density='420',
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
    for target in targets:
        _run_target(target)


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


def _run_target(target: ScreenshotTarget) -> None:
    print(f'Generating {target.name} screenshots...')
    if target.platform == 'ios':
        device_id = _boot_ios_simulator(target.simulator_name or '')
        restore_android = None
    else:
        device_id = _android_device_id()
        restore_android = _configure_android_display(target, device_id)

    try:
        _run_flutter_capture(target, device_id)
    finally:
        if restore_android is not None:
            restore_android()


def _run_flutter_capture(target: ScreenshotTarget, device_id: str) -> None:
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
                [str(ADB), '-s', device_id, 'exec-out', 'screencap', '-p'],
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


def _android_device_id() -> str:
    if not ADB.exists():
        raise RuntimeError(f'adb not found at {ADB}')
    result = subprocess.check_output([str(ADB), 'devices'], text=True)
    for line in result.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == 'device':
            return parts[0]
    raise RuntimeError('No running Android device or emulator found')


def _configure_android_display(
    target: ScreenshotTarget,
    device_id: str,
):
    original_size = subprocess.check_output(
        [str(ADB), '-s', device_id, 'shell', 'wm', 'size'],
        text=True,
    )
    original_density = subprocess.check_output(
        [str(ADB), '-s', device_id, 'shell', 'wm', 'density'],
        text=True,
    )

    subprocess.run(
        [str(ADB), '-s', device_id, 'shell', 'wm', 'size', target.android_size or 'reset'],
        check=True,
    )
    subprocess.run(
        [
            str(ADB),
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
            subprocess.run([str(ADB), '-s', device_id, 'shell', 'wm', 'size', size], check=True)
        else:
            subprocess.run([str(ADB), '-s', device_id, 'shell', 'wm', 'size', 'reset'], check=True)

        if 'Override density:' in original_density:
            density = (
                original_density.split('Override density:', 1)[1].splitlines()[0].strip()
            )
            subprocess.run(
                [str(ADB), '-s', device_id, 'shell', 'wm', 'density', density],
                check=True,
            )
        else:
            subprocess.run(
                [str(ADB), '-s', device_id, 'shell', 'wm', 'density', 'reset'],
                check=True,
            )

    return restore


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
