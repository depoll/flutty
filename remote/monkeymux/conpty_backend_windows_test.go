//go:build windows

package main

import (
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

const conPtyHelperEnvironment = "MONKEYMUX_CONPTY_TEST_HELPER=1"

const conPtyTestRawAPC = "\x1b_Gi=31,a=T,t=d,f=24,s=1,v=1,c=1,r=12;AAAA\x1b\\"

const conPtyTestTmuxDCS = "\x1bPtmux;\x1b\x1b_Gi=32,a=T,t=d,f=24,s=1,v=1,c=1,r=12;AAAA" +
	"\x1b\x1b\\\x1b\\"

func TestBundledConPtyPreservesKittyGraphics(t *testing.T) {
	if os.Getenv("MONKEYMUX_CONPTY_TEST_HELPER") == "1" {
		runConPtyTestHelper()
		os.Exit(0)
	}

	previousCacheRoot := conPtyCacheRoot
	conPtyCacheRoot = t.TempDir()
	t.Cleanup(func() {
		conPtyCacheRoot = previousCacheRoot
	})

	backend, err := loadBundledConPtyBackend()
	if err != nil {
		t.Fatalf("load bundled ConPTY: %v", err)
	}
	if backend.name != "bundled" {
		t.Fatalf("backend name = %q, want bundled", backend.name)
	}
	t.Cleanup(func() {
		if backend.dll != nil {
			_ = windows.FreeLibrary(windows.Handle(backend.dll.Handle()))
		}
	})

	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	commandLine := windows.ComposeCommandLine([]string{
		executable,
		"-test.run=^TestBundledConPtyPreservesKittyGraphics$",
	})
	env := append(os.Environ(), conPtyHelperEnvironment)
	writeHandle, readHandle, hpcon, processHandle, _, err :=
		startConPtyWithBackend(
			backend,
			commandLine,
			env,
			"",
			120,
			40,
		)
	if err != nil {
		t.Fatalf("start helper under bundled ConPTY: %v", err)
	}
	input := os.NewFile(uintptr(writeHandle), "conpty-test-input")
	output := os.NewFile(uintptr(readHandle), "conpty-test-output")
	defer input.Close()
	defer output.Close()

	outputDone := make(chan []byte, 1)
	go func() {
		data, _ := io.ReadAll(output)
		outputDone <- data
	}()

	waitResult, waitErr := windows.WaitForSingleObject(processHandle, 10_000)
	var exitCode uint32
	_ = windows.GetExitCodeProcess(processHandle, &exitCode)
	_ = input.Close()
	backend.close(hpcon)
	windows.CloseHandle(processHandle)
	if waitErr != nil {
		t.Fatalf("wait for helper: %v", waitErr)
	}
	if waitResult != windows.WAIT_OBJECT_0 {
		t.Fatalf("wait result = %d, exit code = 0x%x", waitResult, exitCode)
	}
	if exitCode != 0 {
		t.Fatalf("helper exit code = 0x%x", exitCode)
	}

	var data []byte
	select {
	case data = <-outputDone:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out draining bundled ConPTY output")
	}
	got := string(data)
	for _, expected := range []string{
		conPtyTestRawAPC,
		conPtyTestTmuxDCS,
		"SENTINEL_END",
	} {
		if !strings.Contains(got, expected) {
			t.Errorf("bundled ConPTY output does not contain %q; output=%q", expected, got)
		}
	}
}

func runConPtyTestHelper() {
	stdout, err := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
	if err == nil {
		var mode uint32
		if windows.GetConsoleMode(stdout, &mode) == nil {
			_ = windows.SetConsoleMode(
				stdout,
				mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING,
			)
		}
	}
	_, _ = os.Stdout.WriteString(
		"BEGIN\r\n" +
			conPtyTestRawAPC + "AFTER_APC\r\n" +
			conPtyTestTmuxDCS + "AFTER_DCS\r\n" +
			"SENTINEL_END\r\n",
	)
	time.Sleep(100 * time.Millisecond)
}
