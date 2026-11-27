package driver

import (
	"bytes"
	"testing"
)

func TestTCLCipherRoundTrip(t *testing.T) {
	d := NewTCL("127.0.0.1:6553")
	in := []byte("159hello")
	enc, e := d.Encrypt(in)
	if e != nil {
		t.Fatal(e)
	}
	out, e := d.Decrypt(enc)
	if e != nil || !bytes.Equal(in, out) {
		t.Fatalf("round trip: %q %v", out, e)
	}
}
func TestTCLRejectsBadPadding(t *testing.T) {
	d := NewTCL("x")
	if _, e := d.Decrypt([]byte("bad")); e == nil {
		t.Fatal("expected error")
	}
}
func TestCommandsClosed(t *testing.T) {
	if e := commandAllowed("shell.exec", nil); e == nil {
		t.Fatal("shell must be rejected")
	}
	if e := commandAllowed("tv.power", nil); e == nil {
		t.Fatal("legacy drifted verb must be rejected")
	}
	if e := commandAllowed("power.set", map[string]any{"isOn": false}); e != nil {
		t.Fatalf("canonical verb rejected: %v", e)
	}
	if e := commandAllowed("remote.key", map[string]any{"key": "delete"}); e == nil {
		t.Fatal("key must be rejected")
	}
}
func TestRegisteredDriversUseCanonicalIDs(t *testing.T) {
	for _, id := range RegisteredDrivers {
		d := ForConfig(id, "127.0.0.1:1", "cred")
		if d == nil {
			t.Fatalf("driver %q not registered", id)
		}
		if d.ID() != id {
			t.Fatalf("driver %q reported mismatched ID %q", id, d.ID())
		}
	}
	if ForID("lg_webos", "127.0.0.1:3001") != nil {
		t.Fatal("ForID must not register legacy short aliases directly")
	}
}
