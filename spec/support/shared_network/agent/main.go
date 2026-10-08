// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic test endpoint; this is not shipped or invoked by Empeira production code.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

type Request struct {
	ID      string `json:"id"`
	Op      string `json:"op"`
	Proto   string `json:"proto"`
	Target  string `json:"target"`
	Name    string `json:"name"`
	Want    string `json:"want"`
	Payload []byte `json:"payload"`
}

type Reply struct {
	ID    string `json:"id"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Name  string `json:"name,omitempty"`
	TCP   int    `json:"tcp,omitempty"`
	UDP   int    `json:"udp,omitempty"`
	HTTP  int    `json:"http,omitempty"`
}

const deadline = 2 * time.Second

func endpoints(name string) (Reply, func(), error) {
	tcp, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		return Reply{}, nil, err
	}
	udp, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		tcp.Close()
		return Reply{}, nil, err
	}
	web, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		tcp.Close()
		udp.Close()
		return Reply{}, nil, err
	}
	go func() {
		for {
			conn, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); conn.SetDeadline(time.Now().Add(deadline)); io.Copy(conn, conn) }()
		}
	}()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, addr, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			udp.WriteTo(buf[:n], addr)
		}
	}()
	server := &http.Server{ReadHeaderTimeout: deadline, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, name)
	})}
	go server.Serve(web)
	result := Reply{OK: true, Name: name, TCP: tcp.Addr().(*net.TCPAddr).Port,
		UDP: udp.LocalAddr().(*net.UDPAddr).Port, HTTP: web.Addr().(*net.TCPAddr).Port}
	return result, func() { tcp.Close(); udp.Close(); server.Close() }, nil
}

func exchange(r Request, blocked bool) error {
	if r.Proto != "tcp" && r.Proto != "udp" {
		return fmt.Errorf("unsupported protocol")
	}
	if len(r.Payload) == 0 || len(r.Payload) > 65500 {
		return fmt.Errorf("invalid payload size")
	}
	conn, err := net.DialTimeout(r.Proto+"4", r.Target, deadline)
	if err != nil {
		if blocked {
			return nil
		}
		return err
	}
	defer conn.Close()
	if blocked && r.Proto == "tcp" {
		return fmt.Errorf("unexpected TCP connection to %s", r.Target)
	}
	conn.SetDeadline(time.Now().Add(deadline))
	_, err = io.Copy(conn, bytes.NewReader(r.Payload))
	if err != nil {
		if blocked {
			return nil
		}
		return err
	}
	buf := make([]byte, len(r.Payload))
	if r.Proto == "udp" {
		var n int
		n, err = conn.Read(buf)
		buf = buf[:n]
	} else {
		_, err = io.ReadFull(conn, buf)
	}
	if blocked {
		if err != nil {
			return nil
		}
		return fmt.Errorf("unexpected UDP response from %s", r.Target)
	}
	if err != nil {
		return err
	}
	if !bytes.Equal(buf, r.Payload) {
		return fmt.Errorf("payload integrity failure")
	}
	return nil
}

func resolve(r Request) error {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, r.Target)
	}}
	ips, err := resolver.LookupHost(ctx, r.Name)
	if r.Op == "blocked-dns" {
		if err == nil {
			return fmt.Errorf("unexpected external DNS response")
		}
		return nil
	}
	if err != nil {
		return err
	}
	for _, ip := range ips {
		if ip == r.Want {
			return nil
		}
	}
	return fmt.Errorf("DNS returned %v, wanted %s", ips, r.Want)
}

func execute(r Request, info Reply) Reply {
	out := Reply{ID: r.ID, OK: true}
	var err error
	switch r.Op {
	case "info":
		out = info
		out.ID = r.ID
	case "probe", "blocked":
		err = exchange(r, r.Op == "blocked")
	case "dns", "blocked-dns":
		err = resolve(r)
	case "http":
		client := &http.Client{Timeout: deadline, Transport: &http.Transport{Proxy: nil}}
		var response *http.Response
		response, err = client.Get("http://" + r.Target + "/")
		if err == nil {
			defer response.Body.Close()
			var data []byte
			data, err = io.ReadAll(io.LimitReader(response.Body, 1024))
			if err == nil && string(data) != r.Want {
				err = fmt.Errorf("wrong HTTP identity")
			}
		}
	case "gateway":
		if os.Getpid() != 1 || net.ParseIP(r.Target).To4() == nil {
			err = fmt.Errorf("gateway is guest-only")
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), deadline)
			defer cancel()
			err = exec.CommandContext(ctx, "/bin/busybox", "ip", "route", "replace", "default", "via", r.Target).Run()
		}
	default:
		err = fmt.Errorf("unsupported operation")
	}
	if err != nil {
		out.OK = false
		out.Error = err.Error()
	}
	return out
}

func main() {
	if len(os.Args) < 2 {
		panic("daemon NAME or request JSON")
	}
	if os.Args[1] == "request" {
		var r Request
		if err := json.Unmarshal([]byte(os.Args[2]), &r); err != nil {
			panic(err)
		}
		var info Reply
		if r.Op == "info" {
			data, err := os.ReadFile("/tmp/proof-info.json")
			if err != nil {
				panic(err)
			}
			json.Unmarshal(data, &info)
		}
		reply := execute(r, info)
		json.NewEncoder(os.Stdout).Encode(reply)
		if !reply.OK {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 3 || os.Args[1] != "daemon" || strings.ContainsAny(os.Args[2], "\r\n") {
		panic("invalid daemon arguments")
	}
	info, stop, err := endpoints(os.Args[2])
	if err != nil {
		panic(err)
	}
	defer stop()
	data, _ := json.Marshal(info)
	if err := os.WriteFile("/tmp/proof-info.json", data, 0600); err != nil {
		panic(err)
	}
	if os.Getpid() != 1 {
		select {}
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 128*1024)
	for scanner.Scan() {
		var r Request
		if json.Unmarshal(scanner.Bytes(), &r) != nil {
			continue
		}
		json.NewEncoder(os.Stdout).Encode(execute(r, info))
	}
	select {}
}
