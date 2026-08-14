//go:build windows

package main

import "testing"

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
