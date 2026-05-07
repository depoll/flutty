# MonkeyMux

MonkeyMux is MonkeySSH's purpose-built remote terminal multiplexer. It is a
per-user helper that runs on the SSH target and exposes:

- `monkeymux attach <session>` for the foreground terminal path.
- `monkeymux control <session> --json` for newline-delimited JSON control.

The foreground path is intentionally a direct byte relay. MonkeyMux does not
parse, cache, wrap, or rewrite terminal control sequences in the hot path. All
structured state and commands belong on the control backchannel.

`attach` is the only command that starts a session server. The server and its
windows inherit the environment from the shell that launched `attach` exactly,
so profile-managed values such as `PATH`, `TERM`, and tool-specific variables
remain user-owned instead of being synthesized by MonkeyMux.

Window switching and reconnect repaint from a bounded raw byte history for the
selected window. MonkeyMux still does not parse terminal state; the history is
only a best-effort direct replay so the foreground terminal visibly moves to
the selected PTY.

When `attach` finds an existing server from a different helper version, it asks
before restarting that session. Choosing no attaches to the running server
best-effort so app updates do not silently discard in-progress windows.

The initial target matrix is POSIX-first: Linux and macOS on amd64 and arm64.
Windows support is a later ConPTY-backed follow-up.
