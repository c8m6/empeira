// SPDX-License-Identifier: AGPL-3.0-only
package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
)

// Docker's outer bridge can reflect broadcasts via its hairpin-enabled veth.
// Never relearn guest source MACs on this uplink: they belong to local TAP ports.
// Container destinations still work through unknown-unicast flooding on the uplink.
func disableUplinkLearning(name string) error {
	nic, err := net.InterfaceByName(name)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW, syscall.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	message := make([]byte, 44)
	binary.NativeEndian.PutUint32(message[0:4], uint32(len(message)))
	binary.NativeEndian.PutUint16(message[4:6], syscall.RTM_SETLINK)
	binary.NativeEndian.PutUint16(message[6:8], syscall.NLM_F_REQUEST|syscall.NLM_F_ACK)
	binary.NativeEndian.PutUint32(message[8:12], 1)
	message[16] = syscall.AF_BRIDGE
	binary.NativeEndian.PutUint32(message[20:24], uint32(nic.Index))
	binary.NativeEndian.PutUint16(message[32:34], 12)
	binary.NativeEndian.PutUint16(message[34:36], syscall.IFLA_PROTINFO|0x8000)
	binary.NativeEndian.PutUint16(message[36:38], 5)
	binary.NativeEndian.PutUint16(message[38:40], 8) // IFLA_BRPORT_LEARNING, value 0
	if err = syscall.Sendto(fd, message, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return err
	}
	response := make([]byte, 4096)
	n, _, err := syscall.Recvfrom(fd, response, 0)
	if err != nil {
		return err
	}
	if n < 20 || binary.NativeEndian.Uint16(response[4:6]) != syscall.NLMSG_ERROR {
		return fmt.Errorf("missing bridge netlink acknowledgement")
	}
	code := int32(binary.NativeEndian.Uint32(response[16:20]))
	if code != 0 {
		return syscall.Errno(-code)
	}
	return nil
}
