package rpc

import (
	"bytes"
	"com.menubarhome.tv-bridge/internal/driver"
	"encoding/json"
	"strings"
	"testing"
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

type stubPairer struct{ driver.Base; key string }
func (p *stubPairer) Probe() error                                { return nil }
func (p *stubPairer) Snapshot() (driver.Snapshot, error)          { return driver.Snapshot{ID: "lg_webos_ssap"}, nil }
func (p *stubPairer) Execute(string, map[string]any) error        { return nil }
func (p *stubPairer) Pair() (string, error)                       { return p.key, nil }
func TestPairingBeginAndDynamicCapabilityGeneration(t *testing.T) {
	s := New(&bytes.Buffer{}, t.TempDir())
	if r := s.Handle(req(1, "initialize", map[string]any{"supportedProtocolVersions": []string{"1.0"}, "capabilityGeneration": 4, "config": map[string]any{"devices": []map[string]any{{"nativeId": "lg1", "driver": "lg_webos_ssap", "host": "127.0.0.1", "port": 1, "mac": "AA:BB:CC:DD:EE:FF"}}}})); r.Error != nil {
		t.Fatalf("initialize failed: %+v", r.Error)
	}
	if r := s.Handle(req(2, "control.execute", map[string]any{"nativeId": "lg1", "grantId": "g1", "verb": "power.set", "args": map[string]any{"isOn": false}, "capabilityGeneration": 1})); r.Error == nil {
		t.Fatal("stale capabilityGeneration must be rejected")
	}
	if r := s.Handle(req(3, "pairing.begin", map[string]any{"nativeId": "missing"})); r.Error == nil || r.Error.Code != -32005 {
		t.Fatalf("unknown device pairing must return -32005, got %+v", r.Error)
	}
	s.devices["lg1"] = &stubPairer{key: "paired-key-42"}
	if r := s.Handle(req(4, "pairing.begin", map[string]any{"nativeId": "lg1", "method": "tvUserConsent"})); r.Error != nil || r.Result.(map[string]any)["clientKey"] != "paired-key-42" {
		t.Fatalf("pairing.begin did not return clientKey: %+v", r)
	}
}
