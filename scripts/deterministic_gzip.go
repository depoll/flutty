package main

import (
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: deterministic-gzip <input> <output>")
		os.Exit(2)
	}

	input, err := os.Open(os.Args[1])
	check(err)
	defer input.Close()

	output, err := os.Create(os.Args[2])
	check(err)

	writer, err := gzip.NewWriterLevel(output, gzip.BestCompression)
	check(err)
	writer.Header.ModTime = time.Unix(0, 0).UTC()
	writer.Header.OS = 255

	_, err = io.Copy(writer, input)
	check(err)
	check(writer.Close())
	check(output.Close())
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
