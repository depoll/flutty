import 'dart:convert';

import 'clipboard_sharing_service.dart';
import 'remote_file_service.dart';

/// Result state for a remote clipboard read command.
enum RemoteClipboardReadStatus {
  /// Clipboard text was read and decoded successfully.
  supported,

  /// The remote host has no recognized clipboard command.
  unsupported,

  /// A recognized clipboard command exists but failed for this invocation.
  failed,
}

/// Builds shell commands for syncing the remote machine clipboard over SSH.
///
/// Unlike OSC 52, these commands talk to clipboard utilities on the remote
/// host itself, allowing the app to mirror clipboard changes between the
/// client device and the remote machine when common clipboard tools exist.
class RemoteClipboardSyncService {
  /// Creates a new [RemoteClipboardSyncService].
  const RemoteClipboardSyncService();

  /// Marker emitted when the remote host does not expose a supported clipboard.
  static const unsupportedMarker = '__FLUTTY_REMOTE_CLIPBOARD_UNSUPPORTED__';

  /// Marker emitted when a remote clipboard utility exists but fails to run.
  static const failureMarker = '__FLUTTY_REMOTE_CLIPBOARD_FAILED__';

  /// Returns whether [text] is small enough to sync safely.
  static bool canSyncText(String text) =>
      utf8.encode(text).length <= ClipboardSharingService.maxPayloadBytes;

  /// Builds a remote command that reads the remote clipboard and prints it as
  /// a single base64 line.
  static String buildReadCommand() {
    final unsupported = shellEscapePosix(unsupportedMarker);
    final failed = shellEscapePosix(failureMarker);
    return '''
flutty_clipboard_status=unsupported
flutty_clipboard_data=
flutty_clipboard_find_command() {
  if command -v "\$1" >/dev/null 2>&1; then
    command -v "\$1"
    return 0
  fi
  shift
  for flutty_clipboard_candidate in "\$@"; do
    if [ -x "\$flutty_clipboard_candidate" ]; then
      printf %s "\$flutty_clipboard_candidate"
      return 0
    fi
  done
  return 1
}
flutty_clipboard_try_read() {
  if flutty_clipboard_output="\$("\$@" 2>/dev/null)"; then
    flutty_clipboard_data="\$flutty_clipboard_output"
    flutty_clipboard_status=ok
    return 0
  fi
  if [ "\$flutty_clipboard_status" = unsupported ]; then
    flutty_clipboard_status=failed
  fi
  return 1
}
flutty_clipboard_emit_payload() {
  if command -v base64 >/dev/null 2>&1; then
    printf %s "\$flutty_clipboard_data" | base64 | tr -d '\\r\\n'
  elif command -v python3 >/dev/null 2>&1; then
    printf %s "\$flutty_clipboard_data" | python3 -c 'import base64,sys;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))'
  else
    printf %s $failed
  fi
}
flutty_clipboard_pbpaste="\$(flutty_clipboard_find_command pbpaste /usr/bin/pbpaste)"
flutty_clipboard_reattach="\$(flutty_clipboard_find_command reattach-to-user-namespace "\$HOME/homebrew/bin/reattach-to-user-namespace" /opt/homebrew/bin/reattach-to-user-namespace /usr/local/bin/reattach-to-user-namespace)"
flutty_clipboard_launchctl="\$(flutty_clipboard_find_command launchctl /bin/launchctl)"
if [ -n "\$flutty_clipboard_pbpaste" ]; then
  flutty_clipboard_try_read "\$flutty_clipboard_pbpaste"
fi
if [ "\$flutty_clipboard_status" != ok ] && [ -n "\$flutty_clipboard_reattach" ] && [ -n "\$flutty_clipboard_pbpaste" ]; then
  flutty_clipboard_try_read "\$flutty_clipboard_reattach" "\$flutty_clipboard_pbpaste"
fi
if [ "\$flutty_clipboard_status" != ok ] && [ -n "\$flutty_clipboard_launchctl" ] && [ -n "\$flutty_clipboard_pbpaste" ]; then
  flutty_clipboard_uid="\$(id -u 2>/dev/null || printf '')"
  if [ -n "\$flutty_clipboard_uid" ]; then
    flutty_clipboard_try_read "\$flutty_clipboard_launchctl" asuser "\$flutty_clipboard_uid" "\$flutty_clipboard_pbpaste"
  fi
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v wl-paste >/dev/null 2>&1; then
  flutty_clipboard_try_read wl-paste --no-newline
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v xclip >/dev/null 2>&1; then
  flutty_clipboard_try_read xclip -selection clipboard -o
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v xsel >/dev/null 2>&1; then
  flutty_clipboard_try_read xsel --clipboard --output
fi
case "\$flutty_clipboard_status" in
  ok)
    flutty_clipboard_emit_payload
    ;;
  failed)
    printf %s $failed
    ;;
  *)
    printf %s $unsupported
    ;;
esac
''';
  }

  /// Builds a remote command that writes [text] into the remote clipboard.
  static String buildWriteCommand(String text) {
    final payload = shellEscapePosix(
      ClipboardSharingService.encodePayload(text),
    );
    final unsupported = shellEscapePosix(unsupportedMarker);
    final failed = shellEscapePosix(failureMarker);
    return '''
flutty_clipboard_payload=$payload
if command -v python3 >/dev/null 2>&1; then
  if ! flutty_clipboard_data="\$(python3 -c 'import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1]).decode("utf-8","ignore"))' "\$flutty_clipboard_payload")"; then
    printf %s $failed
    exit 0
  fi
elif command -v base64 >/dev/null 2>&1; then
  if flutty_clipboard_data="\$(printf %s "\$flutty_clipboard_payload" | base64 -d 2>/dev/null)"; then
    :
  elif flutty_clipboard_data="\$(printf %s "\$flutty_clipboard_payload" | base64 -D 2>/dev/null)"; then
    :
  else
    printf %s $failed
    exit 0
  fi
else
  printf %s $failed
  exit 0
fi
flutty_clipboard_status=unsupported
flutty_clipboard_find_command() {
  if command -v "\$1" >/dev/null 2>&1; then
    command -v "\$1"
    return 0
  fi
  shift
  for flutty_clipboard_candidate in "\$@"; do
    if [ -x "\$flutty_clipboard_candidate" ]; then
      printf %s "\$flutty_clipboard_candidate"
      return 0
    fi
  done
  return 1
}
flutty_clipboard_try_write() {
  if printf %s "\$flutty_clipboard_data" | "\$@" 2>/dev/null; then
    flutty_clipboard_status=ok
    return 0
  fi
  if [ "\$flutty_clipboard_status" = unsupported ]; then
    flutty_clipboard_status=failed
  fi
  return 1
}
flutty_clipboard_pbcopy="\$(flutty_clipboard_find_command pbcopy /usr/bin/pbcopy)"
flutty_clipboard_reattach="\$(flutty_clipboard_find_command reattach-to-user-namespace "\$HOME/homebrew/bin/reattach-to-user-namespace" /opt/homebrew/bin/reattach-to-user-namespace /usr/local/bin/reattach-to-user-namespace)"
flutty_clipboard_launchctl="\$(flutty_clipboard_find_command launchctl /bin/launchctl)"
if [ -n "\$flutty_clipboard_pbcopy" ]; then
  flutty_clipboard_try_write "\$flutty_clipboard_pbcopy"
fi
if [ "\$flutty_clipboard_status" != ok ] && [ -n "\$flutty_clipboard_reattach" ] && [ -n "\$flutty_clipboard_pbcopy" ]; then
  flutty_clipboard_try_write "\$flutty_clipboard_reattach" "\$flutty_clipboard_pbcopy"
fi
if [ "\$flutty_clipboard_status" != ok ] && [ -n "\$flutty_clipboard_launchctl" ] && [ -n "\$flutty_clipboard_pbcopy" ]; then
  flutty_clipboard_uid="\$(id -u 2>/dev/null || printf '')"
  if [ -n "\$flutty_clipboard_uid" ]; then
    flutty_clipboard_try_write "\$flutty_clipboard_launchctl" asuser "\$flutty_clipboard_uid" "\$flutty_clipboard_pbcopy"
  fi
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v wl-copy >/dev/null 2>&1; then
  flutty_clipboard_try_write wl-copy
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v xclip >/dev/null 2>&1; then
  flutty_clipboard_try_write xclip -selection clipboard
fi
if [ "\$flutty_clipboard_status" != ok ] && command -v xsel >/dev/null 2>&1; then
  flutty_clipboard_try_write xsel --clipboard --input
fi
case "\$flutty_clipboard_status" in
  ok)
    ;;
  failed)
    printf %s $failed
    ;;
  *)
    printf %s $unsupported
    ;;
esac
''';
  }

  /// Parses the stdout from [buildReadCommand].
  static ({RemoteClipboardReadStatus status, String text}) parseReadOutput(
    String output,
  ) {
    final trimmed = output.trim();
    if (trimmed == unsupportedMarker) {
      return (status: RemoteClipboardReadStatus.unsupported, text: '');
    }
    if (trimmed == failureMarker) {
      return (status: RemoteClipboardReadStatus.failed, text: '');
    }
    final decoded = ClipboardSharingService.decodePayload(trimmed);
    if (decoded == null) {
      return (status: RemoteClipboardReadStatus.failed, text: '');
    }
    return (status: RemoteClipboardReadStatus.supported, text: decoded);
  }

  /// Returns whether a remote write command reported an unsupported clipboard.
  static bool outputIndicatesUnsupported(String output) =>
      output.trim() == unsupportedMarker;

  /// Returns whether a remote clipboard command reported a utility failure.
  static bool outputIndicatesFailure(String output) =>
      output.trim() == failureMarker;
}
