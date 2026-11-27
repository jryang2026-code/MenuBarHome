package driver

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// ConfigurePairing restores host-bound trust and credentials before the driver is used.
func (d *LG) ConfigurePairing(dataDir string) error {
	host := strings.ToLower(strings.TrimSuffix(lgExtractHost(strings.TrimSpace(d.addr)), "."))
	path := filepath.Join(dataDir, "lg-pairing", fmt.Sprintf("%x", sha256.Sum256([]byte(host))))
	pin, err := readLGPrivateFile(path + ".pin")
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil {
		if decoded, err := hex.DecodeString(pin); err != nil || len(decoded) != sha256.Size {
			return errors.New("invalid LG certificate fingerprint")
		}
	}
	key, err := readLGPrivateFile(path + ".key")
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil {
		if pin == "" || strings.TrimSpace(key) == "" {
			return errors.New("invalid LG pairing record")
		}
		if d.ClientKey == "" {
			d.ClientKey = key
		}
	}
	d.pairingPath = path
	d.fingerprint = pin
	return nil
}

func (d *LG) verifyFingerprint(got string) error {
	d.trustMu.Lock()
	defer d.trustMu.Unlock()

	if d.fingerprint == "" {
		pin := got
		if d.pairingPath != "" {
			path := d.pairingPath + ".pin"
			if err := writeLGPrivateFile(path, got, true); err != nil {
				if !errors.Is(err, os.ErrExist) {
					return errors.New("LG certificate fingerprint could not be saved")
				}
				pin, err = readLGPrivateFile(path)
				if err != nil {
					return errors.New("LG certificate fingerprint could not be read")
				}
			}
		}
		d.fingerprint = pin
	}
	if d.fingerprint != got {
		return errors.New("LG TLS fingerprint mismatch")
	}
	return nil
}

func readLGPrivateFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
		return "", errors.New("invalid LG pairing file permissions")
	}
	data, err := os.ReadFile(path)
	return string(data), err
}

func writeLGPrivateFile(path, value string, firstUse bool) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".pairing-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, writeErr := f.WriteString(value)
	if writeErr == nil {
		writeErr = f.Sync()
	}
	closeErr := f.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	if firstUse {
		return os.Link(f.Name(), path)
	}
	return os.Rename(f.Name(), path)
}
