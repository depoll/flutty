# MonkeyMux

MonkeyMux is MonkeySSH's purpose-built remote terminal multiplexer. It is a
per-user helper that runs on the SSH target and exposes:

- `monkeymux attach <session>` for the foreground terminal path.
- `monkeymux control <session> --json` for newline-delimited JSON control.

The foreground path is intentionally a direct byte relay. MonkeyMux does not
parse, cache, wrap, or rewrite terminal control sequences in the hot path. All
structured state and commands belong on the control backchannel.

`attach` is the only command that starts a session server. Optional `--cwd`,
`--name`, and `--command` flags seed the initial window only when a new server
is created, so MonkeySSH can launch a coding agent without creating a duplicate
window on reconnect. The server inherits the environment from the shell that
launched `attach` exactly, so profile-managed values such as `PATH` and
tool-specific variables remain user-owned. PTY windows inherit that environment
and add terminal defaults such as `TERM=xterm-256color` and
`COLORTERM=truecolor` only when the launch environment does not already provide
usable terminal hints. They also advertise `FORCE_HYPERLINK=1` (unless already
set) so OSC 8 capable CLIs such as Copilot and `gh` emit clickable hyperlinks,
which MonkeySSH renders and opens.

Window switching and reconnect repaint from raw byte history for the selected
window. Main-screen shell history is capped for responsive switching; active
alternate-screen, agent, and non-shell foreground program windows replay the
larger retained history so scrollback is restored before the next resize/redraw.
MonkeyMux still does not parse terminal state; the history is
only a best-effort direct replay so the foreground terminal visibly moves to
the selected PTY. Replay strips old terminal response queries, such as device
attributes and OSC color queries, so re-showing history does not synthesize new
input into the live PTY.

MonkeyMux observes OSC title and working-directory reports for metadata only,
without stripping or rewriting those bytes from the foreground stream. It also
tracks the PTY foreground process group for snapshots, so shell-launched tools
such as Codex can be surfaced as agent windows even when the terminal title is
only the current directory. Window replay resets stale local mouse/focus modes
before replaying history so touch input from one window is not leaked into a
plain shell prompt in another. Closing the active window selects the next open
window immediately before the old PTY is torn down.

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

The target matrix covers Linux and macOS on amd64 and arm64, plus Windows on
amd64 and arm64. On Windows the foreground path is backed by a ConPTY
(pseudo console) instead of a POSIX pty; window creation, switching, resize,
byte-relay, and the JSON control channel all work the same way. Windows has no
controlling-terminal foreground process group, so agent detection there falls
back to walking the window shell's child processes, and POSIX-only metadata
probes (process arguments, open files) degrade gracefully.
