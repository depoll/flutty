//go:build windows && arm64

package main

import _ "embed"

//go:embed conpty/win10-arm64/conpty.dll
var bundledConPtyDLL []byte

//go:embed conpty/win10-arm64/OpenConsole.exe
var bundledOpenConsole []byte
