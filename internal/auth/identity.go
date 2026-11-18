package auth

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"database/sql"
	"devicebridge/internal/storage"
	"devicebridge/protocol"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"time"
)

type Identity struct {
	ID, Name    string
	Certificate tls.Certificate
}

func Fingerprint(cert *x509.Certificate) string {
	h := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return hex.EncodeToString(h[:])
}
func Load(s *storage.Store, name string) (*Identity, error) {
	var certPEM, keyPEM []byte
	var savedName string
	err := s.DB.QueryRow("SELECT name,cert,private_key FROM identity WHERE singleton=1").Scan(&savedName, &certPEM, &keyPEM)
	if errors.Is(err, sql.ErrNoRows) {
		if name == "" || len(name) > 128 {
			return nil, errors.New("initialize identity with a device name")
		}
		pub, key, e := ed25519.GenerateKey(rand.Reader)
		if e != nil {
			return nil, e
		}
		serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if e != nil {
			return nil, e
		}
		template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "DeviceBridge"}, NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: time.Now().AddDate(5, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
		der, e := x509.CreateCertificate(rand.Reader, template, template, pub, key)
		if e != nil {
			return nil, e
		}
		pk, e := x509.MarshalPKCS8PrivateKey(key)
		if e != nil {
			return nil, e
		}
		certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pk})
		_, err = s.DB.Exec("INSERT INTO identity(singleton,name,cert,private_key) VALUES(1,?,?,?)", name, certPEM, keyPEM)
		if err != nil {
			return nil, err
		}
		savedName = name
	} else if err != nil {
		return nil, err
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return nil, err
	}
	return &Identity{ID: Fingerprint(leaf), Name: savedName, Certificate: cert}, nil
}
func Validate(cert *x509.Certificate) error {
	if _, ok := cert.PublicKey.(ed25519.PublicKey); !ok {
		return errors.New("Ed25519 device identity required")
	}
	if time.Now().Before(cert.NotBefore) || time.Now().After(cert.NotAfter) {
		return errors.New("expired device certificate")
	}
	return cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature)
}
func (i *Identity) ServerTLS() *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{i.Certificate}, ClientAuth: tls.RequireAnyClientCert, VerifyConnection: func(c tls.ConnectionState) error {
		if len(c.PeerCertificates) != 1 {
			return errors.New("one device certificate required")
		}
		return Validate(c.PeerCertificates[0])
	}}
}
func (i *Identity) ClientTLS(expected string) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{i.Certificate}, InsecureSkipVerify: true, // Private device PKI: verify the exact out-of-band public key below.
		VerifyConnection: func(c tls.ConnectionState) error {
			if len(expected) != 64 || len(c.PeerCertificates) != 1 {
				return errors.New("missing peer pin")
			}
			cert := c.PeerCertificates[0]
			if Fingerprint(cert) != expected {
				return errors.New("device public key mismatch")
			}
			return Validate(cert)
		}}
}
func (i *Identity) Invite(s *storage.Store) (protocol.Invitation, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return protocol.Invitation{}, err
	}
	v := protocol.Invitation{Version: protocol.Version, ID: i.ID, Name: i.Name, Token: base64.RawURLEncoding.EncodeToString(b), Expires: time.Now().Add(5 * time.Minute)}
	return v, s.NewInvite(v.Token, v.Expires)
}
