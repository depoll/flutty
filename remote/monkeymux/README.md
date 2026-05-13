# MonkeyMux

MonkeyMux is MonkeySSH's purpose-built remote terminal multiplexer. It is a
per-user helper that runs on the SSH target and exposes:

- `monkeymux attach <session>` for the foreground terminal path.
- `monkeymux control <session> --json` for newline-delimited JSON control.

The foreground path is intentionally close to a direct byte relay. MonkeyMux
does not emulate a full terminal grid like tmux; it only owns the attached
client's outer alternate buffer and filters nested alternate-buffer toggles
from child PTYs so full-screen TUIs cannot push the app terminal back to the
main buffer mid-session. All structured state and commands belong on the
control backchannel.

`attach` is the only command that starts a session server. Optional `--cwd`,
`--name`, and `--command` flags seed the initial window only when a new server
is created, so MonkeySSH can launch a coding agent without creating a duplicate
window on reconnect. The server and its windows inherit the environment from
the shell that launched `attach` exactly, so profile-managed values such as
`PATH`, `TERM`, and tool-specific variables remain user-owned instead of being
synthesized by MonkeyMux.

Window switching and reconnect repaint from a bounded raw byte history for the
selected window. MonkeyMux still does not parse terminal state; the history is
only a best-effort direct replay so the foreground terminal visibly moves to the
selected PTY. Replay clears and repaints inside the attach-owned alternate
buffer without letting per-window alternate-buffer state leak into the app
terminal. Cursor-addressed agent TUIs that own an alternate buffer skip raw
history replay and are asked to redraw like they are under tmux. Codex is
special-cased because its default chat view uses the main buffer for scrollback:
MonkeyMux replays its main-buffer history, then sends Codex a same-size WINCH
repaint instead of a temporary PTY resize, so stale partial frames do
not remain and Codex never paints against the wrong viewport width. Replay
strips old terminal response queries, such as device attributes, window reports,
mode reports, and OSC color queries, so re-showing history does not synthesize
new input into the live PTY.

MonkeyMux observes OSC title and working-directory reports for metadata only,
without stripping or rewriting those bytes from the foreground stream. It also
tracks the PTY foreground process group for snapshots, so shell-launched tools
such as Codex can be surfaced as agent windows even when the terminal title is
only the current directory. Window replay resets stale local mouse/focus, synchronized-output, and
grapheme-cluster modes before replaying history, and strips synchronized-output
batching controls from the replayed bytes, so touch input, buffered paint state,
or Unicode editing state from one window is not leaked into a plain shell prompt
in another. Closing the active window selects the next open window immediately
before the old PTY is torn down.

Control clients can ask MonkeyMux to run bounded metadata commands through the
server process. This keeps app-side probes on the MonkeyMux backchannel and
uses the environment inherited by the foreground `attach` shell instead of
opening unrelated SSH exec sessions.

Theme/focus refresh requests are backchannel hints. MonkeyMux only forwards
focus transitions to recognized foreground agent TUIs; it does not inject
tmux-style palette reports into shell windows.

When `attach` finds an existing server from a different helper version, it asks
before replacing that session. Choosing no attaches to the running server
best-effort so app updates do not silently discard in-progress windows. If the
old helper predates safe shutdown support, the prompt says the update may
abandon existing windows before starting the newer helper.

The initial target matrix is POSIX-first: Linux and macOS on amd64 and arm64.
Windows support is a later ConPTY-backed follow-up.
