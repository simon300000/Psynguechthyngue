// SPDX-License-Identifier: MIT

package psybridge

// Identity is a freshly generated Syncthing device certificate.
type Identity struct {
	CertPEM  []byte
	KeyPEM   []byte
	DeviceID string
}

// GenerateIdentity creates a new ECDSA device certificate (upstream
// tlsutil.NewCertificate, CN "syncthing"). Swift stores it in the Keychain.
func GenerateIdentity() (*Identity, error) {
	return nil, notImplemented("GenerateIdentity")
}

// DeviceIDFromCertificate returns the device ID for a PEM certificate.
func DeviceIDFromCertificate(certPEM []byte) (string, error) {
	return "", notImplemented("DeviceIDFromCertificate")
}

// ValidateDeviceID normalises user input (QR / paste) into canonical form or
// returns CodeInvalidArgument. Pure function; does not need a running engine.
func ValidateDeviceID(input string) (string, error) {
	return "", notImplemented("ValidateDeviceID")
}
