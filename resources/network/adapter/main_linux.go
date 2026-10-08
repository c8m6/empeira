// SPDX-License-Identifier: AGPL-3.0-only
// Linux endpoint for an authenticated runtime/SSH binary exec channel.
package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

func ioctl(fd int, operation uintptr, value unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), operation, uintptr(value))
	if errno != 0 {
		return errno
	}
	return nil
}

func ifreq(name string) ([40]byte, error) {
	var request [40]byte
	if len(name) == 0 || len(name) > 15 {
		return request, fmt.Errorf("invalid interface name")
	}
	copy(request[:16], name)
	return request, nil
}

func tap(name, bridge string) (*os.File, error) {
	request, err := ifreq(name)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	// TUN_EXCL prevents adopting an existing interface. No persistence: close removes it.
	*(*uint16)(unsafe.Pointer(&request[16])) = 0x0002 | 0x1000 | 0x8000
	if err = ioctl(int(f.Fd()), 0x400454ca, unsafe.Pointer(&request[0])); err != nil {
		f.Close()
		return nil, err
	}
	if err = attach(name, bridge); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func attach(name, bridge string) error {
	nic, err := net.InterfaceByName(name)
	if err != nil {
		return err
	}
	request, err := ifreq(bridge)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	*(*int32)(unsafe.Pointer(&request[16])) = int32(nic.Index)
	if err := ioctl(fd, 0x89a2, unsafe.Pointer(&request[0])); err != nil {
		return err
	} // SIOCBRADDIF
	request, _ = ifreq(name)
	*(*uint16)(unsafe.Pointer(&request[16])) = syscall.IFF_UP
	return ioctl(fd, syscall.SIOCSIFFLAGS, unsafe.Pointer(&request[0]))
}

// Docker's endpoint owns only its container network namespace. A local bridge
// joins its veth to the TAP; the TAP kernel path completes checksum/GSO work
// before frames enter the QEMU stream. No IP/application parsing is necessary.
func localBridge(name, ethernet string) error {
	if _, err := net.InterfaceByName(name); err == nil {
		master, err := os.Readlink("/sys/class/net/" + ethernet + "/master")
		if err != nil || filepath.Base(master) != name {
			return fmt.Errorf("unexpected existing adapter bridge")
		}
		return nil
	}

	req, err := ifreq(name)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	if err = ioctl(fd, 0x89a0, unsafe.Pointer(&req[0])); err != nil {
		return err
	}
	*(*uint16)(unsafe.Pointer(&req[16])) = syscall.IFF_UP
	if err = ioctl(fd, syscall.SIOCSIFFLAGS, unsafe.Pointer(&req[0])); err != nil {
		return err
	}
	if err = attach(ethernet, name); err != nil {
		return err
	}
	if err = disableUplinkLearning(ethernet); err != nil {
		return err
	}
	// The helper is an L2 switch, not an IP gateway. Remove its runtime IPv4 address.
	req, err = ifreq(ethernet)
	if err != nil {
		return err
	}
	*(*uint16)(unsafe.Pointer(&req[16])) = syscall.AF_INET
	if err = ioctl(fd, syscall.SIOCSIFADDR, unsafe.Pointer(&req[0])); err != nil {
		return err
	}

	return nil
}

func bridgeFrames(read func([]byte) (int, error), write func([]byte) error) error {
	done := make(chan error, 2)
	go func() {
		for {
			frame, err := readFrame(os.Stdin)

			if err == nil {
				err = write(frame)
			}
			if err != nil {
				done <- err
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, maxFrame)
		for {
			n, err := read(buf)

			if err == nil {
				err = writeFrame(os.Stdout, buf[:n])
			}
			if err != nil {
				done <- err
				return
			}
		}
	}()
	return <-done
}

func run() error {
	if len(os.Args) == 2 && os.Args[1] == "capabilities" {
		data, err := os.ReadFile("/proc/self/status")
		if err != nil {
			return err
		}
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "CapEff:") {
				fmt.Println(strings.TrimSpace(strings.TrimPrefix(line, "CapEff:")))
				return nil
			}
		}
		return fmt.Errorf("effective capabilities unavailable")
	}

	if len(os.Args) == 2 && os.Args[1] == "hold" {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
		<-signals
		return nil
	}
	if len(os.Args) == 2 && os.Args[1] == "sha256" {
		data, err := os.ReadFile("/proc/self/exe")
		if err != nil {
			return err
		}
		fmt.Printf("%x\n", sha256.Sum256(data))
		return nil
	}

	if len(os.Args) != 4 {
		return fmt.Errorf("usage: adapter tap NAME BRIDGE | bridge NAME INTERFACE")
	}
	if os.Args[1] == "bridge" {
		return localBridge(os.Args[2], os.Args[3])
	}
	if os.Args[1] != "tap" {
		return fmt.Errorf("unsupported mode")
	}
	bridge := os.Args[3]
	f, err := tap(os.Args[2], bridge)
	if err != nil {
		return err
	}
	defer f.Close()
	fd := int(f.Fd())
	if err = syscall.SetNonblock(fd, false); err != nil {
		return err
	}
	// Opened before TUNSETIFF, the descriptor need not have joined Go's netpoller.
	// Use blocking Linux I/O consistently; EOF on the exec channel ends the process.
	return bridgeFrames(func(b []byte) (int, error) { return syscall.Read(fd, b) }, func(b []byte) error {
		n, e := syscall.Write(fd, b)
		if e == nil && n != len(b) {
			e = io.ErrShortWrite
		}
		return e
	})
}

func main() {
	if err := run(); err != nil && err != io.EOF {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
