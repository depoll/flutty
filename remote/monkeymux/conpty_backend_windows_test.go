//go:build windows

package main

import (
	"bytes"
	"encoding/hex"
	"io"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf16"

	"golang.org/x/sys/windows"
)

const conPtyHelperEnvironment = "MONKEYMUX_CONPTY_TEST_HELPER=1"

const conPtyBracketedPasteHelperEnvironment = "MONKEYMUX_CONPTY_BRACKETED_PASTE_TEST_HELPER=1"

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

func TestBundledConPtyPreservesBracketedPasteInWin32InputMode(t *testing.T) {
	if os.Getenv("MONKEYMUX_CONPTY_BRACKETED_PASTE_TEST_HELPER") == "1" {
		runConPtyBracketedPasteTestHelper()
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
		"-test.run=^TestBundledConPtyPreservesBracketedPasteInWin32InputMode$",
	})
	env := append(os.Environ(), conPtyBracketedPasteHelperEnvironment)
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
	input := os.NewFile(uintptr(writeHandle), "conpty-bracketed-paste-input")
	output := os.NewFile(uintptr(readHandle), "conpty-bracketed-paste-output")
	defer input.Close()
	defer output.Close()

	outputDone := make(chan []byte, 1)
	ready := make(chan struct{})
	go func() {
		var data []byte
		buffer := make([]byte, 4096)
		readySent := false
		for {
			count, readErr := output.Read(buffer)
			if count > 0 {
				data = append(data, buffer[:count]...)
				if !readySent && bytes.Contains(data, []byte("READY")) {
					close(ready)
					readySent = true
				}
			}
			if readErr != nil {
				outputDone <- data
				return
			}
		}
	}()

	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for bundled ConPTY helper readiness")
	}
	const paste = "\x1b[200~hello\x1b[201~!"
	encodedPaste := encodeBracketedPasteInputForWin32InputMode([]byte(paste))
	if _, err := input.Write(encodedPaste); err != nil {
		t.Fatalf("write bracketed paste: %v", err)
	}

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
	want := "INPUT_HEX:" + hex.EncodeToString([]byte(paste))
	if got := string(data); !strings.Contains(got, want) {
		t.Fatalf("bundled ConPTY input does not contain %q; output=%q", want, got)
	}
}

func TestSplitBracketedPasteActionsStayClassified(t *testing.T) {
	client := &attachClient{}

	first := client.routeInput([]byte("abc\x1b[20"))
	if !bytes.Equal(first.passthrough, []byte("abc")) ||
		len(first.actions) != 1 ||
		first.actions[0].bracketedPaste {
		t.Fatalf("partial paste start routing = %#v", first)
	}

	second := client.routeInput([]byte("0~hello\x1b[201~"))
	want := []byte("\x1b[200~hello\x1b[201~")
	if !bytes.Equal(second.passthrough, want) ||
		len(second.actions) != 1 ||
		!second.actions[0].bracketedPaste ||
		!bytes.Equal(second.actions[0].data, want) {
		t.Fatalf("completed paste routing = %#v, want %q", second, want)
	}
}

func TestEscapeImmediatelyBeforePastePreservesActionOrder(t *testing.T) {
	client := &attachClient{}
	input := []byte("\x1b\x1b[200~hello\x1b[201~x")

	routing := client.routeInput(input)
	if !bytes.Equal(routing.passthrough, input) ||
		len(routing.actions) != 3 ||
		routing.actions[0].bracketedPaste ||
		!bytes.Equal(routing.actions[0].data, []byte{0x1b}) ||
		!routing.actions[1].bracketedPaste ||
		!bytes.Equal(
			routing.actions[1].data,
			[]byte("\x1b[200~hello\x1b[201~"),
		) ||
		routing.actions[2].bracketedPaste ||
		!bytes.Equal(routing.actions[2].data, []byte("x")) {
		t.Fatalf("escape + paste routing = %#v", routing)
	}
}

func TestAmbiguousPasteStartFlushesAsOrdinaryInput(t *testing.T) {
	passthrough := make(chan []byte, 1)
	claims := make(chan uint64, 1)
	client := &attachClient{
		inputPastePrefixPassthrough: func(data []byte) {
			passthrough <- append([]byte(nil), data...)
		},
		focusSequenceSnapshot: func() uint64 {
			return 42
		},
		focusClaim: func(sequence uint64) {
			claims <- sequence
		},
	}

	routing := client.routeInput([]byte{0x1b})
	if len(routing.passthrough) != 0 {
		t.Fatalf("ambiguous escape routing = %#v", routing)
	}
	select {
	case data := <-passthrough:
		if !bytes.Equal(data, []byte{0x1b}) {
			t.Fatalf("flushed input = %q, want ESC", data)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for ambiguous ESC flush")
	}
	select {
	case sequence := <-claims:
		if sequence != 42 {
			t.Fatalf("focus sequence = %d, want 42", sequence)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for focus claim")
	}
}

func TestLateSplitPasteStartStaysClassified(t *testing.T) {
	flushed := make(chan []byte, 1)
	client := &attachClient{
		inputPastePrefixPassthrough: func(data []byte) {
			flushed <- append([]byte(nil), data...)
		},
	}

	if routing := client.routeInput([]byte{0x1b}); len(routing.passthrough) != 0 {
		t.Fatalf("ambiguous escape routing = %#v", routing)
	}
	select {
	case data := <-flushed:
		if !bytes.Equal(data, []byte{0x1b}) {
			t.Fatalf("flushed prefix = %q, want ESC", data)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for paste prefix flush")
	}

	routing := client.routeInput([]byte("[200~hello\x1b[201~"))
	if len(routing.actions) != 1 ||
		!routing.actions[0].bracketedPaste ||
		!bytes.Equal(
			routing.actions[0].data,
			[]byte("[200~hello\x1b[201~"),
		) {
		t.Fatalf("late split paste routing = %#v", routing)
	}
}

func TestConPtyStartFallsBackAndReturnsActualBackend(t *testing.T) {
	if os.Getenv("MONKEYMUX_CONPTY_TEST_HELPER") == "1" {
		runConPtyTestHelper()
		os.Exit(0)
	}

	previousCacheRoot := conPtyCacheRoot
	conPtyCacheRoot = t.TempDir()
	t.Cleanup(func() {
		conPtyCacheRoot = previousCacheRoot
	})
	fallback, err := loadBundledConPtyBackend()
	if err != nil {
		t.Fatalf("load fallback ConPTY: %v", err)
	}
	t.Cleanup(func() {
		if fallback.dll != nil {
			_ = windows.FreeLibrary(windows.Handle(fallback.dll.Handle()))
		}
	})
	preferred := &conPtyBackend{
		name: "injected-failure",
		create: func(
			windows.Coord,
			windows.Handle,
			windows.Handle,
			uint32,
			*windows.Handle,
		) error {
			return windows.ERROR_INVALID_PARAMETER
		},
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	commandLine := windows.ComposeCommandLine([]string{
		executable,
		"-test.run=^TestConPtyStartFallsBackAndReturnsActualBackend$",
	})
	env := append(os.Environ(), conPtyHelperEnvironment)

	writeHandle, readHandle, hpcon, usedBackend, processHandle, _, err :=
		startConPtyWithFallback(
			preferred,
			fallback,
			commandLine,
			env,
			"",
			120,
			40,
		)
	if err != nil {
		t.Fatalf("start with fallback: %v", err)
	}
	input := os.NewFile(uintptr(writeHandle), "conpty-fallback-input")
	output := os.NewFile(uintptr(readHandle), "conpty-fallback-output")
	defer input.Close()
	defer output.Close()
	if usedBackend != fallback {
		t.Fatalf("used backend = %q, want fallback %q", usedBackend.name, fallback.name)
	}

	waitResult, waitErr := windows.WaitForSingleObject(processHandle, 10_000)
	_ = input.Close()
	usedBackend.close(hpcon)
	windows.CloseHandle(processHandle)
	if waitErr != nil || waitResult != windows.WAIT_OBJECT_0 {
		t.Fatalf("wait result=%d error=%v", waitResult, waitErr)
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

func runConPtyBracketedPasteTestHelper() {
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
	stdin, err := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	if err != nil {
		os.Exit(2)
	}
	var inputMode uint32
	if windows.GetConsoleMode(stdin, &inputMode) == nil {
		inputMode &^= windows.ENABLE_LINE_INPUT |
			windows.ENABLE_ECHO_INPUT |
			windows.ENABLE_PROCESSED_INPUT
		_ = windows.SetConsoleMode(stdin, inputMode)
	}
	_, _ = os.Stdout.WriteString("\x1b[?9001h\x1b[?2004hREADY\r\n")

	var received []uint16
	buffer := make([]uint16, 64)
	for {
		var count uint32
		if err := windows.ReadConsole(
			stdin,
			&buffer[0],
			uint32(len(buffer)),
			&count,
			nil,
		); err != nil {
			os.Exit(3)
		}
		received = append(received, buffer[:count]...)
		if count > 0 && buffer[count-1] == '!' {
			break
		}
	}
	_, _ = os.Stdout.WriteString(
		"INPUT_HEX:" +
			hex.EncodeToString([]byte(string(utf16.Decode(received)))) +
			"\r\n",
	)
}
