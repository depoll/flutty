# Bundled ConPTY backend

These binaries come from Microsoft's official Windows Terminal preview ConPTY
NuGet package:

- Repository: <https://github.com/microsoft/terminal>
- Release: `v1.25.1912.0`
- Package: `Microsoft.Windows.Console.ConPTY.1.25.260710002-preview.nupkg`
- Release URL:
  <https://github.com/microsoft/terminal/releases/tag/v1.25.1912.0>

MonkeyMux uses this paired `conpty.dll` and `OpenConsole.exe` on native Windows
because the system ConPTY strips unsupported APC and DCS control strings,
including Kitty graphics image transmissions. The bundled backend was verified
on Windows build `10.0.26200` to preserve both raw Kitty APC and tmux-wrapped
Kitty DCS byte-for-byte.

This package postdates Microsoft Terminal PR
[#20009](https://github.com/microsoft/terminal/pull/20009), which marks the
ConPTY cursor position dirty after passing through an unknown sequence so the
next console cursor query can resynchronize with the frontend. An older
passthrough backend can display Kitty images but leave native Windows apps
using a stale pre-image cursor.

SHA-256:

| File | SHA-256 |
|---|---|
| `win10-x64/conpty.dll` | `e2fe87e2258c4e46ffc5157f727218cc25f34a174902f72eb8a5b49edd9a6458` |
| `win10-x64/OpenConsole.exe` | `2525c351aa136d555e5df9a3c9d6ce9be43f785e37e3c993b8f23b3f0a53c7fa` |
| `win10-arm64/conpty.dll` | `36a5a3977e83b888f353ce96bae2b5283708630fc43d0f518eaaf2235da8902c` |
| `win10-arm64/OpenConsole.exe` | `197a765e0a0b67a03b142ce9b93b1f428d92f7eee310b110bdf08383ed8d0d73` |

The upstream license is preserved in `LICENSE.microsoft-terminal`.
