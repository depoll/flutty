#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RESAMPLING = getattr(Image, 'Resampling', Image).LANCZOS


@dataclass(frozen=True)
class Scene:
    title: str
    subtitle: str
    renderer: Callable[[ImageDraw.ImageDraw, tuple[int, int, int, int]], None]


def _font(size: int, *, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        '/System/Library/Fonts/SFNS.ttf',
        '/System/Library/Fonts/Supplemental/Arial Bold.ttf' if bold else '/System/Library/Fonts/Supplemental/Arial.ttf',
        '/Library/Fonts/Arial Bold.ttf' if bold else '/Library/Fonts/Arial.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf' if bold else '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    ]
    for path in candidates:
        if path and Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _text_size(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> tuple[int, int]:
    box = draw.textbbox((0, 0), text, font=font)
    return box[2] - box[0], box[3] - box[1]


def _wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
) -> list[str]:
    lines: list[str] = []
    for paragraph in text.split('\n'):
        words = paragraph.split()
        line = ''
        for word in words:
            candidate = word if not line else f'{line} {word}'
            if _text_size(draw, candidate, font)[0] <= max_width:
                line = candidate
            else:
                if line:
                    lines.append(line)
                line = word
        if line:
            lines.append(line)
    return lines


def _gradient(size: tuple[int, int]) -> Image.Image:
    width, height = size
    image = Image.new('RGB', size)
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            t = (x / max(1, width - 1) * 0.35) + (y / max(1, height - 1) * 0.65)
            r = int(8 + (30 * t))
            g = int(18 + (52 * t))
            b = int(27 + (72 * t))
            pixels[x, y] = (r, g, b)
    return image


def _paste_icon(image: Image.Image, draw: ImageDraw.ImageDraw, x: int, y: int, size: int) -> None:
    icon_path = ROOT / 'assets/icons/monkeyssh_icon.png'
    with Image.open(icon_path) as icon:
        icon = icon.convert('RGBA').resize((size, size), RESAMPLING)
        image.paste(icon, (x, y), icon)
    draw.text((x + size + 24, y + 14), 'MonkeySSH', fill=(239, 249, 255), font=_font(36, bold=True))
    draw.text((x + size + 24, y + 58), 'SSH workspace', fill=(140, 178, 195), font=_font(22))


def _card(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], *, fill=(12, 24, 36), outline=(45, 79, 96)) -> None:
    draw.rounded_rectangle(box, radius=34, fill=fill, outline=outline, width=2)


def _phone_frame(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    _card(draw, box, fill=(7, 14, 22), outline=(57, 90, 110))
    left, top, right, bottom = box
    notch_width = int((right - left) * 0.28)
    notch = (
        left + ((right - left - notch_width) // 2),
        top + 18,
        left + ((right - left + notch_width) // 2),
        top + 50,
    )
    draw.rounded_rectangle(notch, radius=16, fill=(2, 7, 12))
    return left + 34, top + 76, right - 34, bottom - 34


def _render_chrome(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int], title: str) -> tuple[int, int, int, int]:
    left, top, right, bottom = area
    draw.rounded_rectangle((left, top, right, bottom), radius=26, fill=(9, 18, 28))
    draw.text((left + 28, top + 22), title, fill=(234, 246, 250), font=_font(28, bold=True))
    draw.rounded_rectangle((right - 102, top + 22, right - 34, top + 58), radius=18, fill=(21, 160, 116))
    draw.text((right - 82, top + 28), 'SSH', fill=(255, 255, 255), font=_font(16, bold=True))
    return left + 22, top + 84, right - 22, bottom - 22


def _draw_terminal(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int]) -> None:
    content = _render_chrome(draw, area, 'Agent workspace')
    _card(draw, content, fill=(3, 10, 17), outline=(28, 52, 64))
    x, y = content[0] + 26, content[1] + 24
    mono = _font(23)
    rows = [
        ('$ tmux attach -t coding', (105, 226, 182)),
        ('monkey@devbox ~/src/app', (134, 191, 217)),
        ('$ copilot resume --recent', (105, 226, 182)),
        ('Found 3 recent agent sessions', (217, 226, 232)),
        ('> fix ssh reconnect flow', (255, 207, 94)),
        ('  review terminal paste guard', (217, 226, 232)),
        ('  polish release metadata', (217, 226, 232)),
    ]
    for text, color in rows:
        draw.text((x, y), text, fill=color, font=mono)
        y += 42
    draw.rounded_rectangle((content[0] + 26, y + 18, content[2] - 26, y + 118), radius=22, fill=(12, 34, 50))
    draw.text((content[0] + 54, y + 42), 'Resume the right coding session', fill=(239, 249, 255), font=_font(24, bold=True))
    draw.text((content[0] + 54, y + 76), 'Recent CLIs scoped to this host', fill=(145, 183, 198), font=_font(18))


def _draw_tmux(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int]) -> None:
    content = _render_chrome(draw, area, 'Tmux navigator')
    labels = [('api', 'running tests'), ('web', 'vite preview'), ('ops', 'tailing logs'), ('agent', 'coding assistant')]
    y = content[1]
    for index, (name, status) in enumerate(labels):
        fill = (20, 82, 79) if index == 0 else (12, 31, 44)
        draw.rounded_rectangle((content[0], y, content[2], y + 94), radius=24, fill=fill)
        draw.text((content[0] + 28, y + 18), name, fill=(239, 249, 255), font=_font(26, bold=True))
        draw.text((content[0] + 28, y + 54), status, fill=(153, 198, 208), font=_font(19))
        draw.text((content[2] - 64, y + 32), f'{index + 1}', fill=(91, 235, 190), font=_font(28, bold=True))
        y += 112
    draw.rounded_rectangle((content[0], y + 8, content[2], content[3]), radius=28, fill=(5, 12, 20))
    draw.text((content[0] + 28, y + 34), 'Windows survive reconnects', fill=(239, 249, 255), font=_font(25, bold=True))
    draw.text((content[0] + 28, y + 72), 'Jump between panes from your phone.', fill=(146, 186, 202), font=_font(19))


def _draw_sftp(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int]) -> None:
    content = _render_chrome(draw, area, 'Remote files')
    files = [
        ('lib/', 'folder'),
        ('pubspec.yaml', 'modified'),
        ('README.md', 'docs'),
        ('deploy.sh', 'script'),
    ]
    y = content[1]
    for name, meta in files:
        draw.rounded_rectangle((content[0], y, content[2], y + 74), radius=20, fill=(12, 31, 44))
        draw.text((content[0] + 26, y + 17), name, fill=(239, 249, 255), font=_font(23, bold=True))
        draw.text((content[2] - 130, y + 21), meta, fill=(126, 174, 190), font=_font(18))
        y += 88
    editor = (content[0], y + 10, content[2], content[3])
    draw.rounded_rectangle(editor, radius=24, fill=(4, 12, 20))
    code = ['Host devbox', '  HostName 10.0.0.42', '  User monkey', '  IdentityFile ~/.ssh/id_ed25519']
    cy = editor[1] + 28
    for line in code:
        draw.text((editor[0] + 28, cy), line, fill=(205, 224, 232), font=_font(20))
        cy += 36


def _draw_automation(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int]) -> None:
    content = _render_chrome(draw, area, 'Automation')
    items = [
        ('Snippet', 'docker compose logs -f api'),
        ('Port forward', 'localhost:5173 -> devbox:5173'),
        ('Auto-connect', 'cd ~/src/app && tmux new -A'),
        ('Safe paste', 'Review suspicious shell text'),
    ]
    y = content[1]
    for label, value in items:
        draw.rounded_rectangle((content[0], y, content[2], y + 104), radius=24, fill=(12, 31, 44))
        draw.text((content[0] + 28, y + 20), label, fill=(91, 235, 190), font=_font(19, bold=True))
        draw.text((content[0] + 28, y + 52), value, fill=(239, 249, 255), font=_font(20))
        y += 122


def _draw_security(draw: ImageDraw.ImageDraw, area: tuple[int, int, int, int]) -> None:
    content = _render_chrome(draw, area, 'Keys and trust')
    center_x = (content[0] + content[2]) // 2
    shield = [
        (center_x, content[1] + 28),
        (center_x + 110, content[1] + 88),
        (center_x + 84, content[1] + 236),
        (center_x, content[1] + 306),
        (center_x - 84, content[1] + 236),
        (center_x - 110, content[1] + 88),
    ]
    draw.polygon(shield, fill=(21, 160, 116), outline=(111, 244, 201))
    draw.text((center_x - 54, content[1] + 128), 'SSH', fill=(255, 255, 255), font=_font(38, bold=True))
    y = content[1] + 360
    for text in ['PIN + biometrics', 'Host-key verification', 'Encrypted transfer bundles']:
        draw.rounded_rectangle((content[0], y, content[2], y + 74), radius=22, fill=(12, 31, 44))
        draw.text((content[0] + 28, y + 20), text, fill=(239, 249, 255), font=_font(22, bold=True))
        y += 92


SCENES = [
    Scene('SSH for agentic coding', 'Resume coding agents and tmux sessions from your phone.', _draw_terminal),
    Scene('Tmux-aware by design', 'Find sessions and windows without losing long-running work.', _draw_tmux),
    Scene('SFTP workspace included', 'Browse, transfer, and edit remote files beside the terminal.', _draw_sftp),
    Scene('Automate repeat work', 'Snippets, auto-connect commands, and port forwards in one place.', _draw_automation),
    Scene('Private by default', 'Keys, trust, and encrypted transfers stay local-first.', _draw_security),
]


def _draw_scene(size: tuple[int, int], scene: Scene) -> Image.Image:
    image = _gradient(size).convert('RGBA')
    draw = ImageDraw.Draw(image)
    width, height = size
    margin = int(width * 0.075)
    _paste_icon(image, draw, margin, int(height * 0.055), int(width * 0.105))

    title_font = _font(int(width * 0.066), bold=True)
    subtitle_font = _font(int(width * 0.034))
    title_y = int(height * 0.17)
    for line in _wrap_text(draw, scene.title, title_font, width - (margin * 2)):
        draw.text((margin, title_y), line, fill=(239, 249, 255), font=title_font)
        title_y += int(width * 0.078)
    subtitle_y = title_y + int(width * 0.012)
    for line in _wrap_text(draw, scene.subtitle, subtitle_font, width - (margin * 2)):
        draw.text((margin, subtitle_y), line, fill=(151, 194, 211), font=subtitle_font)
        subtitle_y += int(width * 0.047)

    phone_top = int(height * 0.36)
    phone_box = (margin, phone_top, width - margin, height - int(height * 0.045))
    scene.renderer(draw, _phone_frame(draw, phone_box))
    return image.convert('RGB')


def _write_screenshot_set(base_dir: Path, size: tuple[int, int]) -> None:
    base_dir.mkdir(parents=True, exist_ok=True)
    for index, scene in enumerate(SCENES, start=1):
        image = _draw_scene(size, scene)
        image.save(base_dir / f'{index}.png', optimize=True)


def _write_ios_screenshots() -> None:
    locale_dir = ROOT / 'ios/fastlane/screenshots/en-US'
    locale_dir.mkdir(parents=True, exist_ok=True)
    for index, scene in enumerate(SCENES, start=1):
        _draw_scene((1320, 2868), scene).save(
            locale_dir / f'{index:02d}_iphone_6_9.png',
            optimize=True,
        )
        _draw_scene((1242, 2688), scene).save(
            locale_dir / f'{index:02d}_iphone_6_5.png',
            optimize=True,
        )


def _write_feature_graphic(path: Path, beta: bool = False) -> None:
    image = _gradient((1024, 500)).convert('RGBA')
    draw = ImageDraw.Draw(image)
    icon_path = ROOT / ('assets/icons/monkeyssh_icon_private.png' if beta else 'assets/icons/monkeyssh_icon.png')
    with Image.open(icon_path) as icon:
        icon = icon.convert('RGBA').resize((148, 148), RESAMPLING)
        image.paste(icon, (72, 72), icon)
    draw.text((250, 88), 'MonkeySSH' + (' beta' if beta else ''), fill=(239, 249, 255), font=_font(58, bold=True))
    draw.text((254, 166), 'SSH workspace for agentic coding', fill=(151, 194, 211), font=_font(34))
    chips = ['Terminal', 'SFTP', 'tmux', 'Agents', 'Port forwards']
    x = 76
    y = 314
    for chip in chips:
        chip_width = _text_size(draw, chip, _font(24, bold=True))[0] + 44
        draw.rounded_rectangle((x, y, x + chip_width, y + 58), radius=29, fill=(12, 45, 58), outline=(43, 92, 110))
        draw.text((x + 22, y + 15), chip, fill=(91, 235, 190), font=_font(24, bold=True))
        x += chip_width + 18
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert('RGB').save(path, optimize=True)


def main() -> None:
    _write_screenshot_set(
        ROOT / 'android/fastlane/metadata-production/android/en-US/images/phoneScreenshots',
        (1080, 1920),
    )
    _write_screenshot_set(
        ROOT / 'android/fastlane/metadata-private/android/en-US/images/phoneScreenshots',
        (1080, 1920),
    )
    _write_ios_screenshots()
    _write_feature_graphic(
        ROOT / 'android/fastlane/metadata-production/android/en-US/images/featureGraphic.png',
    )
    _write_feature_graphic(
        ROOT / 'android/fastlane/metadata-private/android/en-US/images/featureGraphic.png',
        beta=True,
    )


if __name__ == '__main__':
    main()
