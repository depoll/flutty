package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTerminalEnvironmentSetsSafeTerminalDefaults(t *testing.T) {
	env := terminalEnvironment([]string{"PATH=/usr/bin", "USER=test"}, "/bin/zsh")
	values := envMap(env)

	if got := values["TERM"]; got != "xterm-256color" {
		t.Fatalf("TERM = %q, want xterm-256color", got)
	}
	if got := values["COLORTERM"]; got != "truecolor" {
		t.Fatalf("COLORTERM = %q, want truecolor", got)
	}
	if got := values["SHELL"]; got != "/bin/zsh" {
		t.Fatalf("SHELL = %q, want /bin/zsh", got)
	}
	if got := values["PATH"]; got != "/usr/bin" {
		t.Fatalf("PATH = %q, want preserved profile-owned value", got)
	}
}

func TestTerminalEnvironmentPreservesTerminalValues(t *testing.T) {
	env := terminalEnvironment(
		[]string{"TERM=screen-256color", "COLORTERM=24bit", "PATH=/custom/bin"},
		"/bin/bash",
	)
	values := envMap(env)

	if got := values["TERM"]; got != "screen-256color" {
		t.Fatalf("TERM = %q, want screen-256color", got)
	}
	if got := values["COLORTERM"]; got != "24bit" {
		t.Fatalf("COLORTERM = %q, want 24bit", got)
	}
	if got := values["PATH"]; got != "/custom/bin" {
		t.Fatalf("PATH = %q, want preserved custom value", got)
	}
}

func TestTerminalEnvironmentDoesNotGuessMissingPath(t *testing.T) {
	env := terminalEnvironment([]string{"USER=test"}, "/bin/zsh")
	values := envMap(env)

	if _, ok := values["PATH"]; ok {
		t.Fatalf("PATH = %q, want profile-owned PATH to remain unset", values["PATH"])
	}
}

func TestExpandHomePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}

	expanded, err := expandHomePath("~/Code/flutty")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, "Code/flutty"); expanded != want {
		t.Fatalf("expanded path = %q, want %q", expanded, want)
	}

	unchanged, err := expandHomePath("~other/project")
	if err != nil {
		t.Fatal(err)
	}
	if unchanged != "~other/project" {
		t.Fatalf("non-current-user expansion = %q", unchanged)
	}
}

func TestShellCommandStartsLoginShell(t *testing.T) {
	cmd := shellCommand("/bin/zsh")

	if got := cmd.Args[0]; got != "-zsh" {
		t.Fatalf("argv0 = %q, want -zsh", got)
	}
}

func TestLoginShellPathFallsBackToSh(t *testing.T) {
	t.Setenv("SHELL", "")

	if got := loginShellPath(); got != "/bin/sh" {
		t.Fatalf("login shell path = %q, want /bin/sh", got)
	}
}

func envMap(env []string) map[string]string {
	result := map[string]string{}
	for _, item := range env {
		key, value, ok := strings.Cut(item, "=")
		if ok {
			result[key] = value
		}
	}
	return result
}
