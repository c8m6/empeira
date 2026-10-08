// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"encoding/binary"
	"fmt"
	"io"
)

// QEMU stream netdev: a big-endian uint32 length followed by one Ethernet frame.
// No application port or protocol is interpreted here.
const maxFrame = 65535

func readFrame(r io.Reader) ([]byte, error) {
	var size uint32
	if err := binary.Read(r, binary.BigEndian, &size); err != nil {
		return nil, err
	}
	if size < 14 || size > maxFrame {
		return nil, fmt.Errorf("invalid Ethernet frame length %d", size)
	}
	frame := make([]byte, size)
	_, err := io.ReadFull(r, frame)
	return frame, err
}

func writeFrame(w io.Writer, frame []byte) error {
	if len(frame) < 14 || len(frame) > maxFrame {
		return fmt.Errorf("invalid Ethernet frame length %d", len(frame))
	}
	packet := make([]byte, 4+len(frame))
	binary.BigEndian.PutUint32(packet, uint32(len(frame)))
	copy(packet[4:], frame)
	for len(packet) > 0 {
		n, err := w.Write(packet)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		packet = packet[n:]
	}
	return nil
}
