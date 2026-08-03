/// Helpers for running PowerShell logic on Windows OpenSSH remotes.
///
/// Windows remotes run `cmd.exe` or PowerShell rather than a POSIX shell, so the
/// POSIX command layers used for agent-session discovery and shell completion do
/// not work there. Instead of relying on fragile inline quoting across cmd.exe,
/// PowerShell, and the MonkeyMux `run_command` channel, these helpers wrap a
/// PowerShell script into a single
/// `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand`
/// invocation. The `-EncodedCommand` form takes a base64 UTF-16LE payload, which
/// removes all outer-shell quoting concerns: the same command is valid whether it
/// is launched from a cmd.exe default shell, a PowerShell default shell, a plain
/// SSH exec channel, or MonkeyMux's `cmd /c` / `powershell -Command` runner.
///
/// Scripts should target Windows PowerShell 5.1 (always present on supported
/// Windows) and emit their output as UTF-8 bytes written to the raw stdout stream
/// (see [powerShellUtf8OutputPreamble]/[powerShellUtf8OutputEpilogue]) so line
/// endings and Unicode paths survive regardless of the host console code page.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Encodes [script] for `powershell.exe -EncodedCommand`.
///
/// PowerShell expects the argument to be the base64 encoding of the UTF-16
/// little-endian bytes of the script.
String encodePowerShellCommand(String script) {
  final units = script.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    bytes[i * 2] = unit & 0xff;
    bytes[i * 2 + 1] = (unit >> 8) & 0xff;
  }
  return base64.encode(bytes);
}

/// Wraps a PowerShell [script] into a remote command that runs it via
/// `powershell -EncodedCommand`.
///
/// The result is safe to hand to a plain SSH exec channel or the MonkeyMux
/// control channel on a Windows host without any further quoting.
String buildWindowsPowerShellCommand(String script) =>
    'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass '
    '-EncodedCommand ${encodePowerShellCommand(script)}';

/// Quotes [value] as a single-quoted PowerShell string literal.
///
/// PowerShell single-quoted strings are literal (no interpolation or escape
/// sequences). However, PowerShell's tokenizer treats not only the ASCII
/// apostrophe (U+0027) but also U+2018, U+2019, U+201A and U+201B as
/// single-quote delimiters, and all of them are valid in Windows file names. To
/// keep embedding remote paths/globs/tokens injection-safe (a lone curly quote
/// in a filename would otherwise close the literal early and let the remainder
/// execute as code), every quote variant PowerShell recognizes is doubled.
String powerShellSingleQuote(String value) {
  final escaped = value.replaceAllMapped(
    RegExp('[\u0027\u2018\u2019\u201a\u201b]'),
    (match) => '${match[0]}${match[0]}',
  );
  return "'$escaped'";
}

/// PowerShell statements that begin a UTF-8 buffered-output script.
///
/// The script appends output to `$__flOut` (a `StringBuilder`) and flushes it via
/// [powerShellUtf8OutputEpilogue]. Buffering and writing raw UTF-8 bytes avoids
/// depending on `[Console]::OutputEncoding` (which can throw when stdout is a
/// redirected pipe with no attached console) and guarantees LF line endings.
const String powerShellUtf8OutputPreamble =
    r"$ErrorActionPreference='SilentlyContinue';"
    r'$ProgressPreference='
    "'SilentlyContinue';"
    r'$__flOut=New-Object System.Text.StringBuilder;';

/// PowerShell statements that flush the `$__flOut` buffer as UTF-8 bytes to the
/// raw standard output stream.
const String powerShellUtf8OutputEpilogue =
    r'$__flBytes=[System.Text.Encoding]::UTF8.GetBytes($__flOut.ToString());'
    r'$__flStream=[System.Console]::OpenStandardOutput();'
    r'$__flStream.Write($__flBytes,0,$__flBytes.Length);'
    r'$__flStream.Flush();';

/// Wraps [body] (statements that append to `$__flOut`) in the UTF-8 output
/// preamble/epilogue and returns the full script text.
String powerShellUtf8OutputScript(String body) =>
    '$powerShellUtf8OutputPreamble$body$powerShellUtf8OutputEpilogue';

/// PowerShell statements that apply the signed-in user's profile `PATH` to the
/// running process.
///
/// [buildWindowsPowerShellCommand] deliberately passes `-NoProfile` so remote
/// helpers stay fast and cannot be corrupted by profile output. That also hides
/// any CLI whose `PATH` entry is added by a PowerShell profile instead of the
/// persistent machine/user environment — which is exactly how Node version
/// managers (fnm, nvm-windows, volta) and npm/bun global installs are wired up,
/// and therefore how most coding-agent CLIs land on Windows. Scripts that need
/// to resolve user-installed binaries should prepend this so they see the same
/// `PATH` an interactive shell would, mirroring the POSIX side re-invoking
/// `$SHELL -ic`.
///
/// Profiles are run with the call operator rather than dot-sourced, so their
/// functions, aliases, and variables stay out of the calling scope while
/// `$env:Path` edits still apply (the `env:` drive is process-scoped). All
/// output and errors are discarded so a chatty or broken profile cannot corrupt
/// the caller's stdout, and the preferences are re-asserted afterwards in case a
/// profile changed them.
const String powerShellProfilePathPreamble =
    r'$__flProfilePaths = @($PROFILE.AllUsersAllHosts, '
    r'$PROFILE.AllUsersCurrentHost, $PROFILE.CurrentUserAllHosts, '
    r'$PROFILE.CurrentUserCurrentHost) | Where-Object { $_ } | '
    'Select-Object -Unique; '
    r'foreach ($__flProfilePath in $__flProfilePaths) { '
    r'if (Test-Path -LiteralPath $__flProfilePath) { '
    r'try { & $__flProfilePath *> $null } catch {} } }; '
    r"$ErrorActionPreference = 'SilentlyContinue'; "
    r'$ProgressPreference = '
    "'SilentlyContinue';";
