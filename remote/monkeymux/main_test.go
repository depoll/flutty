package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestInheritedEnvironmentPassesThroughLaunchEnvironment(t *testing.T) {
	base := []string{
		"PATH=/custom/bin:/usr/bin",
		"TERM=screen-256color",
		"COLORTERM=24bit",
		"SHELL=/bin/zsh",
		"EMPTY=",
		"PATH=/second-path-entry",
	}

	env := inheritedEnvironment(base)

	if !reflect.DeepEqual(env, base) {
		t.Fatalf("environment = %#v, want exact pass-through %#v", env, base)
	}
	env[0] = "PATH=/changed"
	if base[0] == env[0] {
		t.Fatal("inherited environment aliases source slice")
	}
}

func TestInheritedEnvironmentDoesNotAddMissingValues(t *testing.T) {
	env := inheritedEnvironment([]string{"USER=test"})

	if !reflect.DeepEqual(env, []string{"USER=test"}) {
		t.Fatalf("environment = %#v, want no synthesized values", env)
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

func TestShellCommandUsesPlainShell(t *testing.T) {
	cmd := shellCommand("/bin/zsh")

	if got := cmd.Args[0]; got != "/bin/zsh" {
		t.Fatalf("argv0 = %q, want plain shell argv0", got)
	}
}

func TestDefaultShellPathFallsBackToSh(t *testing.T) {
	t.Setenv("SHELL", "")

	if got := defaultShellPath(); got != "/bin/sh" {
		t.Fatalf("default shell path = %q, want /bin/sh", got)
	}
}
