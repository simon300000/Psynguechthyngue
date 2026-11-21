// SPDX-License-Identifier: MIT

package mobilebridge

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/pem"
	"errors"
	"fmt"

	"github.com/syncthing/syncthing/lib/tlsutil"
)

const (
	identityFormatVersion = uint16(1)
	identityHeaderSize    = 8 + 2 + 4 + 4
	identityChecksumSize  = sha256.Size
	maxIdentityBlobSize   = 1 << 20
)

var identityMagic = [8]byte{'P', 'S', 'Y', 'N', 'G', 'I', 'D', 0}

func generateIdentity() (tls.Certificate, []byte, error) {
	certificate, err := tlsutil.NewCertificateInMemory("syncthing", 20*365)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("generate in-memory identity: %w", err)
	}

	blob, err := encodeIdentity(certificate)
	if err != nil {
		clearPrivateKey(certificate.PrivateKey)
		return tls.Certificate{}, nil, err
	}
	return certificate, blob, nil
}

func encodeIdentity(certificate tls.Certificate) ([]byte, error) {
	if len(certificate.Certificate) != 1 {
		return nil, fmt.Errorf("identity certificate chain must contain exactly one certificate")
	}
	if _, ok := certificate.PrivateKey.(ed25519.PrivateKey); !ok {
		return nil, fmt.Errorf("identity private key must be Ed25519")
	}

	keyDER, err := x509.MarshalPKCS8PrivateKey(certificate.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("encode identity private key: %w", err)
	}
	defer clear(keyDER)

	certificateDER := certificate.Certificate[0]
	if len(certificateDER) == 0 || len(keyDER) == 0 {
		return nil, errors.New("identity contains empty certificate or key data")
	}

	payloadSize := identityHeaderSize + len(certificateDER) + len(keyDER)
	if payloadSize+identityChecksumSize > maxIdentityBlobSize {
		return nil, errors.New("identity blob exceeds the supported size")
	}

	blob := make([]byte, payloadSize+identityChecksumSize)
	copy(blob[:8], identityMagic[:])
	binary.BigEndian.PutUint16(blob[8:10], identityFormatVersion)
	binary.BigEndian.PutUint32(blob[10:14], uint32(len(certificateDER)))
	binary.BigEndian.PutUint32(blob[14:18], uint32(len(keyDER)))
	copy(blob[identityHeaderSize:], certificateDER)
	copy(blob[identityHeaderSize+len(certificateDER):], keyDER)

	checksum := sha256.Sum256(blob[:payloadSize])
	copy(blob[payloadSize:], checksum[:])
	return blob, nil
}

func decodeIdentity(blob []byte) (tls.Certificate, error) {
	if len(blob) < identityHeaderSize+identityChecksumSize {
		return tls.Certificate{}, errors.New("identity blob is truncated")
	}
	if len(blob) > maxIdentityBlobSize {
		return tls.Certificate{}, errors.New("identity blob exceeds the supported size")
	}
	if !bytes.Equal(blob[:8], identityMagic[:]) {
		return tls.Certificate{}, errors.New("identity blob has an invalid magic value")
	}
	if version := binary.BigEndian.Uint16(blob[8:10]); version != identityFormatVersion {
		return tls.Certificate{}, fmt.Errorf("unsupported identity format version %d", version)
	}

	certificateSize := uint64(binary.BigEndian.Uint32(blob[10:14]))
	keySize := uint64(binary.BigEndian.Uint32(blob[14:18]))
	payloadSize := uint64(identityHeaderSize) + certificateSize + keySize
	if certificateSize == 0 || keySize == 0 || payloadSize+identityChecksumSize != uint64(len(blob)) {
		return tls.Certificate{}, errors.New("identity blob has invalid lengths")
	}

	wantChecksum := sha256.Sum256(blob[:payloadSize])
	haveChecksum := blob[payloadSize:]
	if subtle.ConstantTimeCompare(wantChecksum[:], haveChecksum) != 1 {
		return tls.Certificate{}, errors.New("identity blob checksum mismatch")
	}

	certificateEnd := identityHeaderSize + int(certificateSize)
	certificateDER := blob[identityHeaderSize:certificateEnd]
	keyDER := blob[certificateEnd:payloadSize]

	parsedCertificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("parse identity certificate: %w", err)
	}
	if _, ok := parsedCertificate.PublicKey.(ed25519.PublicKey); !ok {
		return tls.Certificate{}, errors.New("identity certificate public key must be Ed25519")
	}
	privateKey, err := x509.ParsePKCS8PrivateKey(keyDER)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("parse identity private key: %w", err)
	}
	parsedPrivateKey, ok := privateKey.(ed25519.PrivateKey)
	if !ok {
		return tls.Certificate{}, errors.New("identity private key must be Ed25519")
	}
	defer clear(parsedPrivateKey)

	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	defer clear(keyPEM)
	certificate, err := tls.X509KeyPair(certificatePEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("validate identity key pair: %w", err)
	}
	return certificate, nil
}

func clearPrivateKey(privateKey any) {
	if key, ok := privateKey.(ed25519.PrivateKey); ok {
		clear(key)
	}
}
