package rpc

import (
	"bytes"
	"com.menubarhome.tv-bridge/internal/driver"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func req(id int, m string, p any) Request {
	b, _ := json.Marshal(p)
	return Request{JSONRPC: "2.0", ID: id, Method: m, Params: b}
}
func TestControlGuards(t *testing.T) {
	s := New(&bytes.Buffer{}, t.TempDir())
	if s.Handle(req(1, "control.execute", map[string]any{"verb": "power.set", "capabilityGeneration": 1})).Error == nil {
		t.Fatal("grant required")
	}
	if s.Handle(req(2, "control.execute", map[string]any{"grantId": "g", "verb": "shell.exec", "capabilityGeneration": 1})).Error == nil {
		t.Fatal("verb guard")
	}
	if s.Handle(req(3, "control.execute", map[string]any{"grantId": "g", "verb": "tv.power", "capabilityGeneration": 1})).Error == nil {
		t.Fatal("legacy verb guard")
	}
	if s.Handle(req(4, "control.execute", map[string]any{"grantId": "g", "verb": "power.set", "capabilityGeneration": 0})).Error == nil {
		t.Fatal("generation guard")
	}
}
func TestInitializeAcceptsCanonicalAndLegacyDriverAliases(t *testing.T) {
	s := New(&bytes.Buffer{}, t.TempDir())
	resp := s.Handle(req(1, "initialize", map[string]any{
		"supportedProtocolVersions": []string{"1.0"},
		"capabilityGeneration":      1,
		"config": map[string]any{
			"devices": []map[string]any{
				{"nativeId": "lg1", "driver": "lg_webos", "host": "127.0.0.1", "port": 3001},
				{"nativeId": "hs1", "driver": "hisense_vidaa_mqtt", "host": "127.0.0.1", "port": 36669},
			},
		},
	}))
	if resp.Error != nil {
		t.Fatalf("initialize failed: %+v", resp.Error)
	}
	if s.devices["lg1"] == nil || s.devices["lg1"].ID() != "lg_webos_ssap" {
		t.Fatalf("legacy lg_webos did not map to lg_webos_ssap")
	}
	if s.devices["hs1"] == nil || s.devices["hs1"].ID() != "hisense_vidaa_mqtt" {
		t.Fatalf("hisense_vidaa_mqtt did not register")
	}
}
func TestArtworkTraversal(t *testing.T) {
	s := New(&bytes.Buffer{}, t.TempDir())
	r := s.Handle(req(1, "media.fetchArtwork", map[string]string{"path": "../secret"}))
	if r.Error == nil {
		t.Fatal("traversal accepted")
	}
}
func TestServeNDJSON(t *testing.T) {
	var out bytes.Buffer
	s := New(&out, t.TempDir())
	if e := s.Serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` + "\n")); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(out.String(), `"manifestDigest"`) {
		t.Fatal(out.String())
	}
}
func TestSleep(t *testing.T) {
	s := New(&bytes.Buffer{}, t.TempDir())
	r := s.Handle(req(1, "host.contextChanged", map[string]bool{"panelVisible": false, "systemActive": true}))
	if r.Error != nil || !s.sleeping {
		t.Fatal("not sleeping")
	}
}

func TestPairingLifecycleAndReload(t *testing.T) {
	const issuedKey = "paired-key-42"
	var registrations, authenticated atomic.Int32
	var rejectPairing atomic.Bool
	tv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(time.Second))
		digest := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		_, _ = fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(digest[:]))
		if rw.Flush() != nil {
			return
		}
		var header, size [2]byte
		if _, err := io.ReadFull(rw, header[:]); err != nil || header != [2]byte{0x81, 0xfe} {
			return
		}
		if _, err := io.ReadFull(rw, size[:]); err != nil {
			return
		}
		var mask [4]byte
		if _, err := io.ReadFull(rw, mask[:]); err != nil {
			return
		}
		body := make([]byte, binary.BigEndian.Uint16(size[:]))
		if _, err := io.ReadFull(rw, body); err != nil {
			return
		}
		for i := range body {
			body[i] ^= mask[i%len(mask)]
		}
		var msg struct {
			Type    string
			Payload struct {
				Key string `json:"client-key"`
			}
		}
		if json.Unmarshal(body, &msg) != nil || msg.Type != "register" {
			return
		}
		registrations.Add(1)
		if msg.Payload.Key == issuedKey {
			authenticated.Add(1)
		}
		reply := []byte(`{"type":"registered","id":"register_0","payload":{"client-key":"` + issuedKey + `"}}`)
		if rejectPairing.Load() {
			reply = []byte(`{"type":"error","id":"register_0","error":"refused ` + issuedKey + `"}`)
		}
		_, _ = conn.Write(append([]byte{0x81, byte(len(reply))}, reply...))
	}))
	defer tv.Close()

	dataDir := t.TempDir()
	initialize := func() *Server {
		t.Helper()
		s := New(&bytes.Buffer{}, dataDir)
		r := s.Handle(req(1, "initialize", map[string]any{
			"supportedProtocolVersions": []string{"1.0"}, "capabilityGeneration": 4,
			"config": map[string]any{"devices": []map[string]any{
				{"nativeId": "lg1", "driver": "lg_webos_ssap", "host": strings.TrimPrefix(tv.URL, "https://")},
			}},
		}))
		if r.Error != nil {
			t.Fatalf("initialize failed: %+v", r.Error)
		}
		return s
	}
	s := initialize()
	if r := s.Handle(req(2, "control.execute", map[string]any{"nativeId": "lg1", "grantId": "g1", "verb": "power.set", "args": map[string]any{"isOn": false}, "capabilityGeneration": 1})); r.Error == nil {
		t.Fatal("stale capabilityGeneration must be rejected")
	}
	begin := func(nativeID, method string) Response {
		return s.Handle(req(3, "pairing.begin", map[string]string{"nativeId": nativeID, "method": method}))
	}
	submit := func(id string, inputs any) Response {
		return s.Handle(req(4, "pairing.submit", map[string]any{"pairingId": id, "inputs": inputs}))
	}
	expectError := func(r Response, code int) {
		t.Helper()
		if r.Error == nil || r.Error.Code != code {
			t.Fatalf("want RPC error %d, got %+v", code, r.Error)
		}
	}
	start := func() string {
		t.Helper()
		r := begin("lg1", "tvUserConsent")
		result, _ := r.Result.(map[string]any)
		id, _ := result["pairingId"].(string)
		instructions, _ := result["instructions"].([]string)
		if r.Error != nil || len(result) != 2 || id == "" || len(instructions) == 0 {
			t.Fatal("pairing.begin must return only pairingId and instructions")
		}
		return id
	}
	expectError(begin("lg1", ""), -32602)
	expectError(begin("missing", "tvUserConsent"), -32005)
	expectError(begin("lg1", "unsupported"), -32004)
	inputs := map[string]string{"userConfirmation": "approved-on-device"}
	expectError(submit("unknown", inputs), -32602)
	cancelled := start()
	cancelParams := map[string]string{"pairingId": cancelled, "reason": "userCancelled"}
	r := s.Handle(req(5, "pairing.cancel", cancelParams))
	cancelResult, _ := r.Result.(map[string]any)
	if r.Error != nil || len(cancelResult) != 1 || cancelResult["cancelled"] != true {
		t.Fatal("pairing.cancel must return only cancelled=true")
	}
	expectError(submit(cancelled, inputs), -32602)
	expectError(s.Handle(req(5, "pairing.cancel", cancelParams)), -32602)

	expiredID := start()
	expired := s.pairings[expiredID]
	expired.expires = time.Now().Add(-time.Second)
	s.pairings[expiredID] = expired
	expectError(submit(expiredID, inputs), -32602)
	pairingID := start()
	expectError(submit(pairingID, map[string]string{"userConfirmation": "invalid"}), -32602)
	if registrations.Load() != 0 {
		t.Fatal("TV was contacted before valid submit")
	}
	rejectPairing.Store(true)
	r = submit(pairingID, inputs)
	expectError(r, -32002)
	if strings.Contains(r.Error.Message, issuedKey) {
		t.Fatal("pairing error exposed a secret")
	}
	expectError(submit(pairingID, inputs), -32602)
	rejectPairing.Store(false)
	pairingID = start()
	r = submit(pairingID, inputs)
	result, _ := r.Result.(map[string]any)
	if r.Error != nil || len(result) != 2 || result["paired"] != true || result["nativeId"] != "lg1" {
		t.Fatalf("pairing.submit failed or returned unexpected data: %+v", r.Error)
	}
	expectError(submit(pairingID, inputs), -32602)
	dir := filepath.Join(dataDir, "lg-pairing")
	files, err := os.ReadDir(dir)
	if err != nil || len(files) != 2 {
		t.Fatalf("expected stored key and pin, got %d files, %v", len(files), err)
	}
	for _, file := range files {
		info, err := file.Info()
		if err != nil {
			t.Fatal(err)
		}
		if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
			t.Fatal("pairing files must be private")
		}
	}
	reloaded := initialize().devices["lg1"].(*driver.LG)
	if err := reloaded.Probe(); err != nil || registrations.Load() != 3 || authenticated.Load() != 1 {
		t.Fatalf("reloaded driver must register using saved pairing: %v", err)
	}
}
