//go:build windows

package main

import "testing"

func TestPiRestoreTreatsWindowsShellsAsShells(t *testing.T) {
	for _, command := range []string{"cmd.exe", "powershell.exe", "pwsh.exe"} {
		state := restoreWindowState{
			CurrentCommand: command,
			PaneTitle:      "Pi - notes",
			AgentTool:      "pi",
		}
		if got := agentToolForRestore(state); got != "" {
			t.Fatalf("Windows shell %q classified as %q", command, got)
		}
		if got := createWindowOptionsForRestore(state, false).command; got != "" {
			t.Fatalf("Windows shell %q restore command = %q", command, got)
		}
		state.AgentToolConfirmed = true
		if got := agentToolForRestore(state); got != "pi" {
			t.Fatalf("confirmed Pi behind Windows shell %q classified as %q", command, got)
		}
		if got := createWindowOptionsForRestore(state, false).command; got != "pi" {
			t.Fatalf("confirmed Pi behind Windows shell %q restore command = %q", command, got)
		}
	}
}

func TestPiRestoreCommandIsSafeForCmd(t *testing.T) {
	t.Setenv("ComSpec", "cmd.exe")
	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got := piResumeCommand("session-id", ""); got != "pi --session session-id" {
		t.Fatalf("ordinary resume command = %q", got)
	}
	if got := piResumeCommandWithFreshFallback("pi --session session-id", "pi"); got != "pi --session session-id || pi" {
		t.Fatalf("cmd fallback command = %q", got)
	}
	t.Setenv("MONKEYMUX_SHELL", "powershell.exe")
	if got := piResumeCommandWithFreshFallback("pi --session session-id", "pi"); got != "pi --session session-id; if (-not $?) { pi }" {
		t.Fatalf("PowerShell fallback command = %q", got)
	}
	t.Setenv("MONKEYMUX_SHELL", "cmd.exe")
	if got := piResumeCommand("session&id", ""); got != "" {
		t.Fatalf("metacharacter resume command = %q, want refusal", got)
	}
	if got, ok := shellArgument(`C:\Program Files\Pi Sessions`); !ok || got != `"C:\Program Files\Pi Sessions"` {
		t.Fatalf("cmd path argument = %q, %v", got, ok)
	}
	if got, ok := shellArgument(`C:\%TEMP%\sessions`); ok || got != "" {
		t.Fatalf("expanding cmd path argument = %q, %v, want refusal", got, ok)
	}
}
