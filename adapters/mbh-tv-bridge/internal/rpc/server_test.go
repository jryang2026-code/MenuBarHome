package rpc

import (
	"bytes"
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
	if s.Handle(req(1, "control.execute", map[string]any{"verb": "tv.power", "capabilityGeneration": 1})).Error == nil {
		t.Fatal("grant required")
	}
	if s.Handle(req(2, "control.execute", map[string]any{"grantId": "g", "verb": "shell.exec", "capabilityGeneration": 1})).Error == nil {
		t.Fatal("verb guard")
	}
	if s.Handle(req(3, "control.execute", map[string]any{"grantId": "g", "verb": "tv.power", "capabilityGeneration": 0})).Error == nil {
		t.Fatal("generation guard")
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
