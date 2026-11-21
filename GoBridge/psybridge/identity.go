// SPDX-License-Identifier: MIT

package psybridge

import (
	"crypto/x509"
	"encoding/pem"
	"strings"

	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/tlsutil"
)

// Identity is a freshly generated Syncthing device certificate.
type Identity struct {
	CertPEM  []byte
	KeyPEM   []byte
	DeviceID string
}

// Same values upstream uses for device certificates (lib/syncthing).
const (
	deviceCertCommonName   = "syncthing"
	deviceCertLifetimeDays = 20 * 365
)

// GenerateIdentity creates a new device certificate exactly like upstream
// (tlsutil.NewCertificateInMemory, CN "syncthing", Ed25519 key, 20 years).
// Swift stores it in the Keychain. The key is PKCS#8 PEM ("PRIVATE KEY").
func GenerateIdentity() (*Identity, error) {
	cert, err := tlsutil.NewCertificateInMemory(deviceCertCommonName, deviceCertLifetimeDays)
	if err != nil {
		return nil, newError(CodeIdentity, "generate certificate: %v", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		return nil, newError(CodeIdentity, "encode key: %v", err)
	}
	return &Identity{
		CertPEM:  pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}),
		KeyPEM:   pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
		DeviceID: protocol.NewDeviceID(cert.Certificate[0]).String(),
	}, nil
}

// DeviceIDFromCertificate returns the device ID for a PEM certificate.
func DeviceIDFromCertificate(certPEM []byte) (string, error) {
	block, _ := pem.Decode(certPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return "", newError(CodeIdentity, "no PEM certificate found")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		return "", newError(CodeIdentity, "invalid certificate: %v", err)
	}
	return protocol.NewDeviceID(block.Bytes).String(), nil
}

// ValidateDeviceID normalises user input (QR / paste) into canonical form or
// returns CodeInvalidArgument. Pure function; does not need a running engine.
func ValidateDeviceID(input string) (string, error) {
	trimmed := strings.TrimSpace(input)
	if trimmed == "" {
		return "", newError(CodeInvalidArgument, "empty device ID")
	}
	id, err := protocol.DeviceIDFromString(trimmed)
	if err != nil {
		return "", newError(CodeInvalidArgument, "invalid device ID: %v", err)
	}
	if id == protocol.EmptyDeviceID || id == protocol.LocalDeviceID {
		return "", newError(CodeInvalidArgument, "reserved device ID")
	}
	return id.String(), nil
}
