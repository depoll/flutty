//go:build windows

package main

import (
	"bytes"
	"io"
	"net"
	"sync"
	"time"
)

// main_test.go contains the shared connection helper but is intentionally
// excluded on Windows. Keep the small subset used by the platform-independent
// capability-query tests available so Windows-only ConPTY integration tests can
// compile in the same package.
type recordingConn struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

type windowsTestAddr string

func (c *recordingConn) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (c *recordingConn) Write(data []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(data)
}

func (c *recordingConn) Close() error {
	return nil
}

func (c *recordingConn) LocalAddr() net.Addr {
	return windowsTestAddr("local")
}

func (c *recordingConn) RemoteAddr() net.Addr {
	return windowsTestAddr("remote")
}

func (c *recordingConn) SetDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) SetReadDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) SetWriteDeadline(time.Time) error {
	return nil
}

func (c *recordingConn) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

func (c *recordingConn) Reset() {
	c.mu.Lock()
	c.buf.Reset()
	c.mu.Unlock()
}

func (a windowsTestAddr) Network() string {
	return string(a)
}

func (a windowsTestAddr) String() string {
	return string(a)
}
