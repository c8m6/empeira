// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

type shortWriter struct{ bytes.Buffer }

func (w *shortWriter) Write(b []byte) (int, error) {
	if len(b) > 3 {
		b = b[:3]
	}
	return w.Buffer.Write(b)
}

func TestFrameRoundTrip(t *testing.T) {
	var stream shortWriter
	want := bytes.Repeat([]byte{0, 255, 42}, 500)
	for i := 0; i < 2; i++ {
		if err := writeFrame(&stream, want); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		got, err := readFrame(&stream)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("frame mismatch: %v", err)
		}
	}
	if _, err := readFrame(&stream); err != io.EOF {
		t.Fatalf("wanted EOF: %v", err)
	}
}

func TestInvalidLengths(t *testing.T) {
	for _, n := range []uint32{0, 13, 65536, 0xffffffff} {
		var stream bytes.Buffer
		binary.Write(&stream, binary.BigEndian, n)
		if _, err := readFrame(&stream); err == nil {
			t.Fatalf("accepted %d", n)
		}
	}
	var truncated bytes.Buffer
	binary.Write(&truncated, binary.BigEndian, uint32(100))
	truncated.Write(make([]byte, 14))
	if _, err := readFrame(&truncated); err != io.ErrUnexpectedEOF {
		t.Fatal(err)
	}
}
