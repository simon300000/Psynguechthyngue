// SPDX-License-Identifier: MIT

//go:build peerinterop

package integration

import (
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/simon300000/Psynguechthyngue/GoCore/mobilebridge"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

type rejectedProtocolFixture string

const (
	rejectedLegacyHello       rejectedProtocolFixture = "legacy-hello"
	rejectedUnknownHello      rejectedProtocolFixture = "unknown-hello"
	rejectedOversizedHello    rejectedProtocolFixture = "oversized-hello"
	rejectedNegativeBEPHeader rejectedProtocolFixture = "negative-bep-header"
)

func TestConfiguredPeerRejectsLegacyAndMalformedProtocolWithoutStoppingCore(t *testing.T) {
	for _, fixture := range []rejectedProtocolFixture{
		rejectedLegacyHello,
		rejectedUnknownHello,
		rejectedOversizedHello,
		rejectedNegativeBEPHeader,
	} {
		t.Run(string(fixture), func(t *testing.T) {
			runRejectedProtocolFixture(t, fixture)
		})
	}
}

func runRejectedProtocolFixture(t *testing.T, fixture rejectedProtocolFixture) {
	t.Helper()
	testRoot := t.TempDir()
	bridgeHome := filepath.Join(testRoot, "bridge-home")
	if err := os.MkdirAll(bridgeHome, 0o700); err != nil {
		t.Fatal(err)
	}

	core, err := mobilebridge.NewCore(bridgeHome, nil)
	if err != nil {
		t.Fatal(err)
	}
	coreClosed := false
	t.Cleanup(func() {
		if !coreClosed {
			_ = core.Close()
		}
	})
	bridgeIdentity := core.IdentityBlob()
	t.Cleanup(func() { clear(bridgeIdentity) })
	bridgeID := mustDeviceID(t, core.DeviceID())

	peerCertificate, err := tlsutil.NewCertificateInMemory("syncthing", 30)
	if err != nil {
		t.Fatalf("generate protocol-boundary identity: %v", err)
	}
	peerID := protocol.NewDeviceID(peerCertificate.Certificate[0])

	bridgeReservation := listenProtocolFixtureTCP(t)
	peerRawListener := listenProtocolFixtureTCP(t)
	guiReservation := listenProtocolFixtureTCP(t)
	bridgeAddress := bridgeReservation.Addr().String()
	peerAddress := peerRawListener.Addr().String()
	guiAddress := guiReservation.Addr().String()
	writeBridgeBootstrapConfig(t, bridgeHome, bridgeID, bridgeAddress, guiAddress)
	if err := bridgeReservation.Close(); err != nil {
		t.Fatalf("release bridge address reservation: %v", err)
	}
	if err := guiReservation.Close(); err != nil {
		t.Fatalf("release GUI address reservation: %v", err)
	}

	tlsConfiguration := tlsutil.SecureDefaultTLS13()
	tlsConfiguration.Certificates = []tls.Certificate{peerCertificate}
	tlsConfiguration.ClientAuth = tls.RequestClientCert
	tlsConfiguration.NextProtos = []string{"bep/1.0"}
	tlsConfiguration.SessionTicketsDisabled = true
	tlsConfiguration.InsecureSkipVerify = true // The peer identity is verified by its certificate-derived Device ID.
	peerListener := tls.NewListener(peerRawListener, tlsConfiguration)
	t.Cleanup(func() { _ = peerListener.Close() })
	peerResult := make(chan error, 1)
	go func() {
		peerResult <- serveRejectedProtocolPeer(peerListener, fixture, bridgeID)
	}()

	if err := core.Start(); err != nil {
		t.Fatalf("start protocol-boundary core: %v", err)
	}
	commandOK(t, core, "add-protocol-boundary-peer", "addDevice", "", peerID.String(), map[string]string{
		"name":      "protocol-boundary-peer",
		"addresses": "tcp://" + peerAddress,
		"paused":    "false",
	})

	select {
	case err := <-peerResult:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("configured core did not reach the protocol-boundary peer")
	}
	waitForDisconnected(t, core, peerID.String(), 10*time.Second)
	for attempt := range 5 {
		current := snapshot(t, core, fmt.Sprintf("protocol-rejection-%s-%d", fixture, attempt))
		if !current.Running {
			t.Fatal("malformed peer input stopped the embedded core")
		}
		configured := false
		for _, device := range current.Devices {
			if device.DeviceID != peerID.String() {
				continue
			}
			configured = true
			if device.Connected {
				t.Fatal("rejected protocol peer remained connected")
			}
		}
		if !configured {
			t.Fatal("protocol rejection mutated the configured peer")
		}
		for _, pending := range current.PendingDevices {
			if pending.DeviceID == peerID.String() {
				t.Fatal("configured malformed peer was demoted into an untrusted pending offer")
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	commandOK(t, core, "ping-after-"+string(fixture), "ping", "", "", nil)
	if err := core.Stop(); err != nil {
		t.Fatalf("stop core after protocol rejection: %v", err)
	}
	if err := core.Close(); err != nil {
		t.Fatalf("close core after protocol rejection: %v", err)
	}
	coreClosed = true
}

func listenProtocolFixtureTCP(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	return listener
}

func serveRejectedProtocolPeer(
	listener net.Listener,
	fixture rejectedProtocolFixture,
	expectedBridgeID protocol.DeviceID,
) error {
	connection, err := listener.Accept()
	if err != nil {
		return fmt.Errorf("accept protocol-boundary connection: %w", err)
	}
	defer connection.Close()
	_ = listener.Close()
	if err := connection.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return fmt.Errorf("set protocol-boundary deadline: %w", err)
	}
	tlsConnection, ok := connection.(*tls.Conn)
	if !ok {
		return errors.New("protocol-boundary listener did not return a TLS connection")
	}
	if err := tlsConnection.Handshake(); err != nil {
		return fmt.Errorf("complete protocol-boundary TLS handshake: %w", err)
	}
	state := tlsConnection.ConnectionState()
	if state.NegotiatedProtocol != "bep/1.0" {
		return fmt.Errorf("unexpected negotiated protocol %q", state.NegotiatedProtocol)
	}
	if len(state.PeerCertificates) != 1 || protocol.NewDeviceID(state.PeerCertificates[0].Raw) != expectedBridgeID {
		return errors.New("protocol-boundary peer received an unexpected bridge identity")
	}

	switch fixture {
	case rejectedLegacyHello:
		if err := readBEPHelloFrame(tlsConnection); err != nil {
			return err
		}
		if err := binary.Write(tlsConnection, binary.BigEndian, protocol.Version13HelloMagic); err != nil {
			return fmt.Errorf("write legacy hello magic: %w", err)
		}
	case rejectedUnknownHello:
		if err := readBEPHelloFrame(tlsConnection); err != nil {
			return err
		}
		if err := binary.Write(tlsConnection, binary.BigEndian, uint32(0xDEADBEEF)); err != nil {
			return fmt.Errorf("write unknown hello magic: %w", err)
		}
	case rejectedOversizedHello:
		if err := readBEPHelloFrame(tlsConnection); err != nil {
			return err
		}
		frame := make([]byte, 6)
		binary.BigEndian.PutUint32(frame[:4], protocol.HelloMessageMagic)
		binary.BigEndian.PutUint16(frame[4:], ^uint16(0))
		if _, err := tlsConnection.Write(frame); err != nil {
			return fmt.Errorf("write oversized hello frame: %w", err)
		}
	case rejectedNegativeBEPHeader:
		if _, err := protocol.ExchangeHello(tlsConnection, protocol.Hello{
			DeviceName:    "protocol-boundary-peer",
			ClientName:    "protocol-boundary-fixture",
			ClientVersion: "0",
			Timestamp:     time.Now().UnixNano(),
		}); err != nil {
			return fmt.Errorf("exchange valid hello before malformed BEP frame: %w", err)
		}
		if _, err := tlsConnection.Write([]byte{0xff, 0xff}); err != nil {
			return fmt.Errorf("write negative BEP header length: %w", err)
		}
	default:
		return fmt.Errorf("unknown rejected protocol fixture %q", fixture)
	}
	return waitForProtocolRejectionClose(tlsConnection)
}

func readBEPHelloFrame(reader io.Reader) error {
	header := make([]byte, 6)
	if _, err := io.ReadFull(reader, header); err != nil {
		return fmt.Errorf("read bridge hello header: %w", err)
	}
	if magic := binary.BigEndian.Uint32(header[:4]); magic != protocol.HelloMessageMagic {
		return fmt.Errorf("bridge hello magic = 0x%08x", magic)
	}
	length := binary.BigEndian.Uint16(header[4:])
	if length > 32767 {
		return fmt.Errorf("bridge hello length %d exceeds the protocol maximum", length)
	}
	if _, err := io.CopyN(io.Discard, reader, int64(length)); err != nil {
		return fmt.Errorf("read bridge hello payload: %w", err)
	}
	return nil
}

func waitForProtocolRejectionClose(connection net.Conn) error {
	if err := connection.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return fmt.Errorf("set protocol rejection read deadline: %w", err)
	}
	buffer := make([]byte, 4096)
	total := 0
	for {
		count, err := connection.Read(buffer)
		total += count
		if total > 1<<20 {
			return errors.New("rejected peer received more than 1 MiB before disconnect")
		}
		if err == nil {
			continue
		}
		var networkError net.Error
		if errors.As(err, &networkError) && networkError.Timeout() {
			return errors.New("core did not close the rejected protocol connection")
		}
		return nil
	}
}
