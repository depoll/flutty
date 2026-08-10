//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAssignPiSessionsByWorkingDirectoryOnWindows(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	project := filepath.Join(home, "project")
	sessionDir := filepath.Join(
		home,
		".pi",
		"agent",
		"sessions",
		"--project--",
	)
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeSession := func(name string, sessionID string, modified time.Time) {
		t.Helper()
		header, err := json.Marshal(map[string]string{
			"type": "session",
			"id":   sessionID,
			"cwd":  project,
		})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(sessionDir, name)
		if err := os.WriteFile(path, append(header, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, modified, modified); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now()
	writeSession(
		"2026-08-10T07-20-00-000Z_windows-unclaimed-session.jsonl",
		"windows-unclaimed-session",
		now.Add(-time.Minute),
	)
	writeSession(
		"2026-08-10T07-30-00-000Z_windows-claimed-session.jsonl",
		"windows-claimed-session",
		now,
	)
	restore := &serverRestore{
		Windows: []restoreWindowState{
			{
				Name:           "project",
				Cwd:            project,
				PaneTitle:      "π - project",
				AgentSessionID: "windows-claimed-session",
			},
			{
				Name:      "project two",
				Cwd:       project,
				PaneTitle: "π - project",
			},
		},
	}

	assignPiSessionsByWorkingDirectory(restore)

	if got := restore.Windows[1].AgentSessionID; got !=
		"windows-unclaimed-session" {
		t.Fatalf(
			"Pi session id = %q, want windows-unclaimed-session",
			got,
		)
	}
}
