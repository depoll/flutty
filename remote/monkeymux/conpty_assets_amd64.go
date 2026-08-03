//go:build windows && amd64

package main

import _ "embed"

//go:embed conpty/win10-x64/conpty.dll
var bundledConPtyDLL []byte

//go:embed conpty/win10-x64/OpenConsole.exe
var bundledOpenConsole []byte
