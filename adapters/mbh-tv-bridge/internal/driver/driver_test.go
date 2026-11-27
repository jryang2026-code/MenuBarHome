package driver

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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
	if snap, err := d.Snapshot(); err != nil || snap.ID != "hisense_vidaa_mqtt" || snap.Power != "on" {
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
			resp, _ := json.Marshal(map[string]any{"type": "response", "id": req.ID, "payload": pl}); _ = wsWriteText(c, resp)
		}
	})
	d := NewLG(addr, true); d.Timeout, d.PairTimeout = 2*time.Second, 2*time.Second
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
	_ = ln.Close(); wg.Wait(); mu.Lock(); defer mu.Unlock()
	if sawKey != "issued-lg-key-99" || len(ptrMsgs) != 1 || !strings.Contains(ptrMsgs[0], "name:HOME") { t.Fatalf("key=%q ptr=%v", sawKey, ptrMsgs) }
	for _, want := range []string{"ssap://system/turnOff", "ssap://audio/setVolume", "ssap://audio/setMute", "ssap://tv/switchInput", "ssap://media.controls/play", "ssap://media.controls/pause", "ssap://media.controls/stop"} {
		if !strings.Contains(strings.Join(uris, ","), want) { t.Fatalf("missing %s", want) }
	}
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
func TestHisenseVIDAAEdgeCasesTimeoutRedactionAndTLS(t *testing.T) {
	var wg sync.WaitGroup
	authLn, _ := net.Listen("tcp", "127.0.0.1:0")
	serveLoop(&wg, authLn, func(c net.Conn) { var buf [128]byte; if n, err := c.Read(buf[:]); err == nil && n > 0 && buf[0] == 0x10 { _, _ = c.Write([]byte{0x20, 0x02, 0x00, 0x05}) } })
	dAuth := NewHisenseVIDAA(authLn.Addr().String(), "myuser:TopSecretPass99"); dAuth.Timeout = time.Second
	if err := dAuth.Probe(); err == nil || strings.Contains(err.Error(), "TopSecretPass99") || strings.Contains(err.Error(), "myuser") { t.Fatalf("auth err leaked: %v", err) }
	_ = authLn.Close()
	hangLn, _ := net.Listen("tcp", "127.0.0.1:0"); serveLoop(&wg, hangLn, func(c net.Conn) { time.Sleep(350 * time.Millisecond) })
	dHang := NewHisenseVIDAA(hangLn.Addr().String(), "u:secret"); dHang.Timeout = 100 * time.Millisecond; t0 := time.Now()
	if err := dHang.Probe(); err == nil || time.Since(t0) > time.Second { t.Fatalf("expected timeout: %v %v", err, time.Since(t0)) }
	_ = hangLn.Close()
	tlsLn, _ := tls.Listen("tcp", "127.0.0.1:0", testSelfSignedTLS(t))
	serveLoop(&wg, tlsLn, func(c net.Conn) { var buf [128]byte; if _, err := c.Read(buf[:]); err == nil && buf[0] == 0x10 { _, _ = c.Write([]byte{0x20, 0x02, 0x00, 0x00}) } })
	dTLS := NewHisenseVIDAA(tlsLn.Addr().String(), ""); dTLS.Timeout = time.Second
	if snap, err := dTLS.Snapshot(); err != nil || snap.Power != "on" { t.Fatalf("TLS Hisense: %+v %v", snap, err) }
	_ = tlsLn.Close(); wg.Wait()
}
