package driver

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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
	ln, err := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t))
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var published [][2]string
	var reject atomic.Bool
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
				if reject.Load() {
					_, _ = conn.Write([]byte{0x20, 0x02, 0x00, 0x05})
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
	defer func() { _ = ln.Close(); wg.Wait() }()
	d := NewHisenseVIDAA(ln.Addr().String(), "")
	if snap, err := d.Snapshot(); err != nil || snap.ID != "hisense_vidaa_mqtt" || snap.Power != "on" {
		t.Fatalf("snapshot failed: %+v %v", snap, err)
	}
	for _, tc := range []struct {
		verb      string
		args      map[string]any
		fail      bool
		wantMuted bool
	}{
		{"mute.set", map[string]any{"isMuted": true}, true, false},
		{"mute.set", map[string]any{"isMuted": true}, false, true},
		{"mute.set", map[string]any{"isMuted": true}, false, true},
		{"mute.set", map[string]any{"isMuted": false}, true, true},
		{"mute.set", map[string]any{"isMuted": false}, false, false},
		{"mute.set", map[string]any{"isMuted": false}, false, false},
		{"remote.key", map[string]any{"key": "mute"}, false, true},
		{"remote.key", map[string]any{"key": "mute"}, true, true},
		{"remote.key", map[string]any{"key": "mute"}, false, false},
	} {
		reject.Store(tc.fail)
		if err := d.Execute(tc.verb, tc.args); (err != nil) != tc.fail {
			t.Fatalf("%s %v, expected failure=%t: %v", tc.verb, tc.args, tc.fail, err)
		}
		reject.Store(false)
		if snap, err := d.Snapshot(); err != nil || snap.Muted != tc.wantMuted {
			t.Fatalf("snapshot after %s %v, rejected=%t: muted=%t, want %t, error=%v", tc.verb, tc.args, tc.fail, snap.Muted, tc.wantMuted, err)
		}
	}
	for _, tc := range []struct {
		verb string
		args map[string]any
		fail bool
	}{
		{"power.set", map[string]any{"isOn": true}, false},
		{"power.set", map[string]any{"isOn": false}, false},
		{"volume.set", map[string]any{"level": 42}, false},
		{"input.select", map[string]any{"source": "HDMI1"}, false},
		{"remote.key", map[string]any{"key": "home"}, false},
		{"media.playPause", nil, true},
		{"media.playPause", nil, false},
		{"media.playPause", nil, true},
		{"media.playPause", nil, false},
		{"media.play", nil, false},
		{"media.pause", nil, false},
		{"media.stop", nil, false},
	} {
		reject.Store(tc.fail)
		if err := d.Execute(tc.verb, tc.args); (err != nil) != tc.fail {
			t.Fatalf("%s, expected failure=%t: %v", tc.verb, tc.fail, err)
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
	var payloads []string
	for _, msg := range published {
		payloads = append(payloads, msg[1])
	}
	want := []string{"KEY_MUTE", "KEY_MUTE", "KEY_MUTE", "KEY_MUTE", "KEY_POWER", "42", `{"sourceid":"HDMI1","sourcename":"HDMI1"}`, "KEY_HOME", "KEY_PLAY", "KEY_PAUSE", "KEY_PLAY", "KEY_PAUSE", "KEY_STOP"}
	if !slices.Equal(payloads, want) {
		t.Fatalf("MQTT payloads = %q, want %q", payloads, want)
	}
}

func testSelfSignedTLS(t *testing.T) *tls.Config {
	t.Helper(); k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k); if err != nil { t.Fatal(err) }
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: k}}}
}
func wsServerAccept(conn net.Conn) (*bufio.Reader, string, error) {
	br := bufio.NewReader(conn); reqLine, err := br.ReadString('\n'); if err != nil { return nil, "", err }
	path := "/"; if parts := strings.Fields(reqLine); len(parts) >= 2 { path = parts[1] }
	var key string
	for { ln, err := br.ReadString('\n'); if err != nil { return nil, "", err }; if ln = strings.TrimSpace(ln); ln == "" { break }; if k, v, ok := strings.Cut(ln, ":"); ok && strings.EqualFold(strings.TrimSpace(k), "sec-websocket-key") { key = strings.TrimSpace(v) } }
	h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	_, err = io.WriteString(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+base64.StdEncoding.EncodeToString(h[:])+"\r\n\r\n")
	return br, path, err
}
func wsReadFrame(br *bufio.Reader) ([]byte, error) {
	var h [2]byte; if _, err := io.ReadFull(br, h[:]); err != nil { return nil, err }
	n := int(h[1] & 0x7f); if n == 126 { var b [2]byte; if _, err := io.ReadFull(br, b[:]); err != nil { return nil, err }; n = int(binary.BigEndian.Uint16(b[:])) }
	var mask [4]byte; if h[1]&0x80 != 0 { if _, err := io.ReadFull(br, mask[:]); err != nil { return nil, err } }
	p := make([]byte, n); if _, err := io.ReadFull(br, p); err != nil { return nil, err }
	if h[1]&0x80 != 0 { for i := range p { p[i] ^= mask[i%4] } }
	return p, nil
}
func wsWriteText(w io.Writer, msg []byte) error {
	hdr := []byte{0x81, byte(len(msg))}; if len(msg) >= 126 { hdr = []byte{0x81, 126, byte(len(msg) >> 8), byte(len(msg))} }
	_, err := w.Write(append(hdr, msg...)); return err
}
func serveLoop(wg *sync.WaitGroup, ln net.Listener, h func(net.Conn)) {
	wg.Add(1); go func() { defer wg.Done(); for { c, err := ln.Accept(); if err != nil { return }; wg.Add(1); go func(conn net.Conn) { defer wg.Done(); defer conn.Close(); h(conn) }(c) } }()
}
func TestLGWebOSHandshakeControlSnapshotAndWOL(t *testing.T) {
	ln, err := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t)); if err != nil { t.Fatal(err) }
	addr := ln.Addr().String(); var mu sync.Mutex; var uris, ptrMsgs []string; var sawKey string; var wg sync.WaitGroup
	var rejectMedia atomic.Bool
	serveLoop(&wg, ln, func(c net.Conn) {
		br, path, err := wsServerAccept(c); if err != nil { return }
		if path == "/pointer" { if raw, err := wsReadFrame(br); err == nil { mu.Lock(); ptrMsgs = append(ptrMsgs, string(raw)); mu.Unlock() }; return }
		for {
			raw, err := wsReadFrame(br); if err != nil { return }
			var req struct{ ID, Type, URI string; Payload map[string]any }; if json.Unmarshal(raw, &req) != nil { return }
			if req.Type == "register" {
				if ck, _ := req.Payload["client-key"].(string); ck == "" {
					_ = wsWriteText(c, []byte(`{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT"}}`))
					_ = wsWriteText(c, []byte(`{"type":"registered","id":"register_0","payload":{"client-key":"issued-lg-key-99"}}`))
				} else { mu.Lock(); sawKey = ck; mu.Unlock(); _ = wsWriteText(c, []byte(`{"type":"registered","id":"register_0","payload":{"client-key":"`+ck+`"}}`)) }
				continue
			}
			mu.Lock(); uris = append(uris, req.URI); mu.Unlock()
			var pl any = map[string]any{"returnValue": true}
			switch req.URI {
			case "ssap://audio/getVolume": pl = map[string]any{"returnValue": true, "volume": 37, "muted": true}
			case "ssap://com.webos.applicationManager/getForegroundAppInfo": pl = map[string]any{"returnValue": true, "appId": "com.webos.app.hdmi2"}
			case "ssap://com.webos.service.networkinput/getPointerInputSocket": pl = map[string]any{"returnValue": true, "socketPath": "wss://" + addr + "/pointer"}
			}
			if strings.HasPrefix(req.URI, "ssap://media.controls/") && rejectMedia.Swap(false) {
				pl = map[string]any{"returnValue": false}
			}
			resp, _ := json.Marshal(map[string]any{"type": "response", "id": req.ID, "payload": pl}); _ = wsWriteText(c, resp)
		}
	})
	defer func() { _ = ln.Close(); wg.Wait() }()
	dataDir := t.TempDir()
	d := NewLG(addr, true); d.Timeout, d.PairTimeout = 2*time.Second, 2*time.Second
	if err := d.ConfigurePairing(dataDir); err != nil { t.Fatal(err) }
	if key, err := d.Pair(); err != nil || key != "issued-lg-key-99" { t.Fatalf("Pair: %q %v", key, err) }
	if snap, err := d.Snapshot(); err != nil || snap.Power != "on" || snap.Volume != 37 || !snap.Muted || snap.Source != "HDMI 2" { t.Fatalf("LG snap: %+v %v", snap, err) }
	udpLn, err := net.ListenPacket("udp4", "127.0.0.1:0"); if err != nil { t.Fatal(err) }; defer udpLn.Close()
	d.SetMAC("AA:BB:CC:DD:EE:FF"); d.wolTarget = udpLn.LocalAddr().String()
	if err := d.Execute("power.set", map[string]any{"isOn": true}); err != nil { t.Fatalf("WoL: %v", err) }
	buf := make([]byte, 128); _ = udpLn.SetReadDeadline(time.Now().Add(time.Second))
	if n, _, err := udpLn.ReadFrom(buf); err != nil || n != 102 || !bytes.Equal(buf[:6], bytes.Repeat([]byte{0xff}, 6)) { t.Fatalf("WoL pkt: %d %v", n, err) }
	for _, tc := range []struct{ v string; a map[string]any }{
		{"power.set", map[string]any{"isOn": false}}, {"power.screenOff", map[string]any{}}, {"volume.set", map[string]any{"level": float64(55)}}, {"mute.set", map[string]any{"isMuted": false}},
		{"input.select", map[string]any{"source": "HDMI 3"}}, {"remote.key", map[string]any{"key": "home"}}, {"remote.key", map[string]any{"key": "volumeUp"}}, {"media.play", map[string]any{}}, {"media.pause", map[string]any{}}, {"media.stop", map[string]any{}}, {"media.playPause", map[string]any{}},
	} { if err := d.Execute(tc.v, tc.a); err != nil { t.Fatalf("LG %s: %v", tc.v, err) } }
	for _, reject := range []bool{true, false, false} {
		rejectMedia.Store(reject)
		if err := d.Execute("media.playPause", nil); (err != nil) != reject {
			t.Fatalf("LG playPause: expected rejection=%t, got %v", reject, err)
		}
	}
	reloaded := NewLG(addr, true)
	if err := reloaded.ConfigurePairing(dataDir); err != nil { t.Fatal(err) }
	if err := reloaded.Probe(); err != nil { t.Fatal(err) }

	changed, err := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t))
	if err != nil { t.Fatal(err) }
	var reachedUpgrade atomic.Bool
	serveLoop(&wg, changed, func(c net.Conn) {
		if _, _, err := wsServerAccept(c); err == nil { reachedUpgrade.Store(true) }
	})
	defer changed.Close()
	untrusted := NewLG(changed.Addr().String(), true)
	if err := untrusted.ConfigurePairing(dataDir); err != nil { t.Fatal(err) }
	if err := untrusted.Probe(); err == nil || !strings.Contains(err.Error(), "fingerprint mismatch") {
		t.Fatalf("LG must reject a different certificate: %v", err)
	}
	_ = ln.Close(); _ = changed.Close(); wg.Wait()
	if reachedUpgrade.Load() { t.Fatal("LG sent a WebSocket upgrade to the untrusted certificate") }
	mu.Lock(); defer mu.Unlock()
	if sawKey != "issued-lg-key-99" || len(ptrMsgs) != 1 || !strings.Contains(ptrMsgs[0], "name:HOME") { t.Fatalf("key=%q ptr=%v", sawKey, ptrMsgs) }
	for _, want := range []string{"ssap://system/turnOff", "ssap://audio/setVolume", "ssap://audio/setMute", "ssap://tv/switchInput", "ssap://media.controls/play", "ssap://media.controls/pause", "ssap://media.controls/stop"} {
		if !strings.Contains(strings.Join(uris, ","), want) { t.Fatalf("missing %s", want) }
	}
	if got := uris[len(uris)-3:]; !slices.Equal(got, []string{"ssap://media.controls/pause", "ssap://media.controls/pause", "ssap://media.controls/play"}) {
		t.Fatalf("LG playPause commands = %q", got)
	}
}
func TestLGConfigurePairingRejectsMissingStorageOrHost(t *testing.T) {
	dataDir := t.TempDir()
	for _, tc := range []struct {
		name, addr, dataDir string
	}{
		{"empty_directory", "127.0.0.1:3001", ""},
		{"blank_directory", "127.0.0.1:3001", " \t"},
		{"empty_host", "", dataDir},
		{"blank_host", " \t", dataDir},
		{"port_only", ":3001", dataDir},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Chdir(t.TempDir())
			d := NewLG(tc.addr, true)
			if err := d.ConfigurePairing(tc.dataDir); err == nil {
				t.Error("ConfigurePairing accepted missing storage or host")
			}
			if err := d.verifyFingerprint(strings.Repeat("a", 64)); err != nil {
				t.Fatalf("verifyFingerprint: %v", err)
			}
			for _, dir := range []string{".", dataDir} {
				entries, err := os.ReadDir(dir)
				if err != nil || len(entries) != 0 {
					t.Errorf("pairing storage %q must stay empty: %v, %v", dir, entries, err)
				}
			}
		})
	}
}

func TestReadLGPrivateFileRejectsUnsafeFiles(t *testing.T) {
	t.Run("permissions", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("Windows does not expose Unix file permissions")
		}
		path := filepath.Join(t.TempDir(), "device.key")
		if err := os.WriteFile(path, []byte("test-key"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0644); err != nil {
			t.Fatal(err)
		}
		if _, err := readLGPrivateFile(path); err == nil {
			t.Error("readLGPrivateFile accepted a non-0600 file")
		}
	})
	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target")
		if err := os.WriteFile(target, []byte("test-key"), 0600); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "device.key")
		if err := os.Symlink(target, path); err != nil {
			if runtime.GOOS == "windows" {
				t.Skipf("cannot create a Windows symlink: %v", err)
			}
			t.Fatal(err)
		}
		if _, err := readLGPrivateFile(path); err == nil {
			t.Error("readLGPrivateFile accepted a symbolic link")
		}
	})
}

func TestXiaomi6095SnapshotAndCommands(t *testing.T) {
	var mu sync.Mutex; alive, volStep := true, 3; var actions []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock(); defer mu.Unlock()
		switch r.URL.Path {
		case "/request": if !alive { http.Error(w, "off", 503); return }; _, _ = w.Write([]byte(`{"status":0,"data":{"devicename":"客厅小米电视"}}`))
		case "/general": _ = json.NewEncoder(w).Encode(map[string]any{"status": 0, "data": map[string]any{"volum": volStep, "maxvolum": 15}})
		case "/controller":
			if r.URL.Query().Get("action") == "keyevent" {
				code := r.URL.Query().Get("keycode"); actions = append(actions, "key:"+code)
				if code == "volumeup" && volStep < 15 { volStep++ } else if code == "volumedown" && volStep > 0 { volStep-- }
			} else { actions = append(actions, "src:"+r.URL.Query().Get("source")) }
			_, _ = w.Write([]byte(`{"status":0}`))
		}
	})); defer srv.Close()
	d := NewXiaomi(srv.URL)
	if snap, err := d.Snapshot(); err != nil || snap.Power != "on" || snap.Volume != 20 || snap.Name != "客厅小米电视" { t.Fatalf("Xiaomi snap: %+v %v", snap, err) }
	for _, tc := range []struct{ v string; a map[string]any }{
		{"power.set", map[string]any{"isOn": true}}, {"volume.set", map[string]any{"level": float64(40)}}, {"mute.set", map[string]any{"isMuted": true}}, {"input.select", map[string]any{"source": "HDMI 2"}},
		{"remote.key", map[string]any{"key": "select"}}, {"media.playPause", map[string]any{}}, {"media.stop", map[string]any{}}, {"power.set", map[string]any{"isOn": false}},
	} { if err := d.Execute(tc.v, tc.a); err != nil { t.Fatalf("Xiaomi %s: %v", tc.v, err) } }
	if err := d.Execute("volume.set", map[string]any{"level": 120}); err == nil { t.Fatal("invalid volume must fail") }
	mu.Lock(); alive = false; got := strings.Join(actions, ","); mu.Unlock()
	if err := d.Execute("power.set", map[string]any{"isOn": true}); err == nil { t.Fatal("cold wake must fail offline") }
	if _, err := d.Snapshot(); err == nil { t.Fatal("offline snapshot must fail") }
	if want := "key:volumeup,key:volumeup,key:volumeup,key:mute,src:hdmi2,key:enter,key:playpause,key:stop,key:power"; got != want { t.Fatalf("got %s want %s", got, want) }
}
func TestHisenseVIDAACredentialRedactionAndTLS(t *testing.T) {
	var wg sync.WaitGroup
	authLn, _ := net.Listen("tcp", "127.0.0.1:0")
	serveLoop(&wg, authLn, func(c net.Conn) { var buf [128]byte; if n, err := c.Read(buf[:]); err == nil && n > 0 && buf[0] == 0x10 { _, _ = c.Write([]byte{0x20, 0x02, 0x00, 0x05}) } })
	dAuth := NewHisenseVIDAA(authLn.Addr().String(), "myuser:TopSecretPass99"); dAuth.Timeout = time.Second; dAuth.Plaintext = true
	if err := dAuth.Probe(); err == nil || strings.Contains(err.Error(), "TopSecretPass99") || strings.Contains(err.Error(), "myuser") { t.Fatalf("auth err leaked: %v", err) }
	_ = authLn.Close()
	tlsLn, _ := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t))
	serveLoop(&wg, tlsLn, func(c net.Conn) { var buf [128]byte; if _, err := c.Read(buf[:]); err == nil && buf[0] == 0x10 { _, _ = c.Write([]byte{0x20, 0x02, 0x00, 0x00}) } })
	dTLS := NewHisenseVIDAA(tlsLn.Addr().String(), ""); dTLS.Timeout = time.Second
	if snap, err := dTLS.Snapshot(); err != nil || snap.Power != "on" { t.Fatalf("TLS Hisense: %+v %v", snap, err) }
	_ = tlsLn.Close(); wg.Wait()
}

func TestHisenseMQTTCredentials(t *testing.T) {
	for _, tc := range []struct {
		name, credential, wantUser, wantPassword string
	}{
		{"empty", "", "hisenseservice", "multimqttservice"},
		{"blank", " \t", "hisenseservice", "multimqttservice"},
		{"PIN", "1234", "hisenseservice", "1234"},
		{"explicit", "user:pass", "user", "pass"},
		{"no_username", ":pass", "hisenseservice", "pass"},
		{"separator_only", ":", "hisenseservice", "multimqttservice"},
		{"no_password", "user:", "user", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := NewHisenseVIDAA("127.0.0.1", tc.credential)
			user, password := d.mqttCreds()
			if user != tc.wantUser || password != tc.wantPassword {
				t.Errorf("mqttCreds() = (%q, %q), want (%q, %q)", user, password, tc.wantUser, tc.wantPassword)
			}
		})
	}
}

func TestHisenseTransportFallback(t *testing.T) {
	for _, tc := range []struct {
		name string
		reply []byte
		fallback bool
	}{
		{"non-TLS", []byte("HTTP/1.0 400 Bad Request\r\n\r\n"), true},
		{"TLS alert", []byte{0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28}, false},
		{"EOF", []byte{}, false},
		{"timeout", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil { t.Fatal(err) }
			var wg sync.WaitGroup
			var attempts atomic.Int32
			var gotPIN atomic.Bool
			serveLoop(&wg, ln, func(c net.Conn) {
				attempts.Add(1)
				_ = c.SetDeadline(time.Now().Add(2 * time.Second))
				var hdr [2]byte
				if _, err := io.ReadFull(c, hdr[:]); err != nil { return }
				if hdr[0] == 0x10 {
					body := make([]byte, int(hdr[1]))
					if _, err := io.ReadFull(c, body); err == nil {
						gotPIN.Store(bytes.HasSuffix(body, []byte("\x00\x0ehisenseservice\x00\x041234")))
						_, _ = c.Write([]byte{0x20, 0x02, 0x00, 0x00})
					}
				} else if tc.reply == nil {
					_, _ = io.Copy(io.Discard, c)
				} else {
					_, _ = c.Write(tc.reply)
				}
			})
			d := NewHisenseVIDAA(ln.Addr().String(), "1234")
			d.Timeout = 500 * time.Millisecond
			err = d.Probe()
			_ = ln.Close()
			wg.Wait()
			wantAttempts := int32(1)
			if tc.fallback { wantAttempts++ }
			if (err == nil) != tc.fallback || attempts.Load() != wantAttempts || gotPIN.Load() != tc.fallback {
				t.Fatalf("Probe error = %v, dial attempts = %d, received PIN = %t", err, attempts.Load(), gotPIN.Load())
			}
		})
	}
}

func TestXiaomiVolumeFullRange(t *testing.T) {
	var volume atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/general":
			_ = json.NewEncoder(w).Encode(map[string]any{"volume": volume.Load(), "maxVolume": 100})
		case r.URL.Query().Get("keycode") == "volumeup":
			volume.Add(1)
		case r.URL.Query().Get("keycode") == "volumedown":
			volume.Add(-1)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	d := NewXiaomi(srv.URL)
	for _, level := range []int{100, 0} {
		if err := d.Execute("volume.set", map[string]any{"level": level}); err != nil {
			t.Fatal(err)
		}
		if got := volume.Load(); int(got) != level {
			t.Fatalf("volume = %d, want %d", got, level)
		}
	}
}

func TestXiaomiVolumeInterrupted(t *testing.T) {
	var keyPresses atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/general" {
			_, _ = io.WriteString(w, `{"volume":0,"maxVolume":100}`)
			return
		}
		keyPresses.Add(1)
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer srv.Close()
	d := NewXiaomi(srv.URL)
	d.client.Timeout = 500 * time.Millisecond
	err := d.Execute("volume.set", map[string]any{"level": 100})
	if !errors.Is(err, context.DeadlineExceeded) || keyPresses.Load() != 1 {
		t.Fatalf("interrupted volume operation error = %v, key presses = %d", err, keyPresses.Load())
	}
}

func TestTVHTTPRedirectsStayOnOrigin(t *testing.T) {
	var destinationHits atomic.Int32
	var sonyRequests atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		destinationHits.Add(1)
		_, _ = io.WriteString(w, `{"status":0}`)
	}))
	defer target.Close()
	for _, destination := range []string{target.URL, strings.Replace(target.URL, "127.0.0.1", "localhost", 1), ""} {
		source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-Auth-PSK") == "test-psk" {
				sonyRequests.Add(1)
			}
			location := destination
			if location == "" {
				location = "https://" + r.Host + "/"
			}
			http.Redirect(w, r, location, http.StatusFound)
		}))
		for _, tv := range []TVDriver{NewXiaomi(source.URL), NewSony(source.URL, "test-psk")} {
			if err := tv.Probe(); err == nil || !strings.Contains(err.Error(), "cross-origin TV redirect refused") {
				t.Errorf("%s probe should refuse cross-origin redirect, got %v", tv.ID(), err)
			}
		}
		source.Close()
	}
	if destinationHits.Load() != 0 {
		t.Fatal("redirect destination received a request")
	}
	if sonyRequests.Load() != 3 {
		t.Fatal("Sony must send the PSK to its configured endpoint")
	}
}

func TestSamsungTokenInWebSocketRequest(t *testing.T) {
	ln, err := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t))
	if err != nil { t.Fatal(err) }
	paths := make(chan string, 3)
	var wg sync.WaitGroup
	serveLoop(&wg, ln, func(c net.Conn) {
		br, path, err := wsServerAccept(c)
		if err != nil { return }
		paths <- path
		_, _ = wsReadFrame(br)
	})
	defer func() { _ = ln.Close(); wg.Wait() }()
	d := NewSamsung(ln.Addr().String())
	token := "example+/?&= token"
	for i, value := range []string{token, token, ""} {
		d.Token = value
		var err error
		if i == 1 {
			err = d.Execute("remote.key", map[string]any{"key": "home"})
		} else {
			err = d.Probe()
		}
		if err != nil { t.Fatal(err) }
		path := <-paths
		u, err := url.ParseRequestURI(path)
		if err != nil { t.Fatal(err) }
		query := u.Query()
		if u.Path != "/api/v2/channels/samsung.remote.control" || query.Get("name") != base64.StdEncoding.EncodeToString([]byte("MenuBarHome")) ||
			query.Get("token") != value || query.Has("token") != (value != "") {
			t.Fatal("unexpected Tizen WebSocket endpoint")
		}
	}
}
