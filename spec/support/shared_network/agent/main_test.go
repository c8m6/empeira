package main

import (
	"bytes"
	"fmt"
	"testing"
)

func TestPayloadsAndDenial(t *testing.T) {
	info, close, err := endpoints("fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer close()
	for _, protocol := range []string{"tcp", "udp"} {
		port := info.TCP
		if protocol == "udp" {
			port = info.UDP
		}
		r := Request{ID: "test", Op: "probe", Proto: protocol, Target: fmt.Sprintf("127.0.0.1:%d", port), Payload: bytes.Repeat([]byte{0, 255, 13, 10, 128}, 200)}
		if reply := execute(r, info); !reply.OK {
			t.Fatal(reply)
		}
		r.Op = "blocked"
		if reply := execute(r, info); reply.OK {
			t.Fatal("reachable endpoint reported blocked")
		}
	}
	r := Request{Op: "http", Target: fmt.Sprintf("127.0.0.1:%d", info.HTTP), Want: "fixture"}
	if reply := execute(r, info); !reply.OK {
		t.Fatal(reply)
	}
	if execute(Request{Op: "unknown"}, info).OK {
		t.Fatal("unknown operation accepted")
	}
}
