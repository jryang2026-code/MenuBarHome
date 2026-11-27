package driver

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"sync"
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
func TestHisenseVIDAAMQTTCommands(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var published [][2]string
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		readPkt := func(conn net.Conn) (byte, []byte, error) {
			var b [1]byte
			if _, err := io.ReadFull(conn, b[:]); err != nil {
				return 0, nil, err
			}
			hdr := b[0]
			if hdr != 0x10 && hdr != 0x30 && hdr != 0xE0 {
				return 0, nil, io.EOF
			}
			rem, mult := 0, 1
			for {
				if _, err := io.ReadFull(conn, b[:]); err != nil {
					return 0, nil, err
				}
				rem += int(b[0]&0x7f) * mult
				if b[0]&0x80 == 0 {
					break
				}
				mult *= 128
			}
			body := make([]byte, rem)
			_, err := io.ReadFull(conn, body)
			return hdr, body, err
		}
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			func(conn net.Conn) {
				defer conn.Close()
				if hdr, _, err := readPkt(conn); err != nil || hdr != 0x10 {
					return
				}
				_, _ = conn.Write([]byte{0x20, 0x02, 0x00, 0x00})
				if hdr, body, err := readPkt(conn); err == nil && hdr == 0x30 && len(body) >= 2 {
					tlen := int(binary.BigEndian.Uint16(body[:2]))
					if 2+tlen <= len(body) {
						mu.Lock()
						published = append(published, [2]string{string(body[2 : 2+tlen]), string(body[2+tlen:])})
						mu.Unlock()
					}
				}
			}(c)
		}
	}()
	d := NewHisenseVIDAA(ln.Addr().String(), "")
	if snap, err := d.Snapshot(); err != nil || snap.ID != "hisense_vidaa_mqtt" {
		t.Fatalf("snapshot failed: %+v %v", snap, err)
	}
	for _, tc := range []struct{ verb string; args map[string]any }{
		{"power.set", map[string]any{"isOn": false}}, {"volume.set", map[string]any{"level": float64(42)}},
		{"mute.set", map[string]any{"isMuted": true}}, {"input.select", map[string]any{"source": "HDMI1"}},
		{"remote.key", map[string]any{"key": "home"}}, {"media.play", map[string]any{}},
		{"media.pause", map[string]any{}}, {"media.stop", map[string]any{}},
	} {
		if err := d.Execute(tc.verb, tc.args); err != nil {
			t.Fatalf("%s failed: %v", tc.verb, err)
		}
	}
	if err := d.Execute("volume.set", map[string]any{"level": 150}); err == nil {
		t.Fatal("out-of-range volume must fail")
	}
	if err := d.Execute("input.select", map[string]any{"source": ""}); err == nil {
		t.Fatal("empty source must fail")
	}
	_ = ln.Close()
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if len(published) != 8 || published[1][1] != "42" || published[4][1] != "KEY_HOME" {
		t.Fatalf("unexpected MQTT publishes: %+v", published)
	}
}
