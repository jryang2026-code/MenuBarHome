package rpc

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
)

const MaxFrame = 8 * 1024 * 1024

type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}
type Response struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id,omitempty"`
	Result  any       `json:"result,omitempty"`
	Error   *RPCError `json:"error,omitempty"`
}
type RPCError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}
type Server struct {
	mu             sync.Mutex
	initialized    bool
	sleeping       bool
	generation     int64
	dataDir        string
	manifestDigest string
	out            io.Writer
	quit           bool
}

func New(out io.Writer, dataDir string) *Server {
	return &Server{out: out, dataDir: dataDir, generation: 1, manifestDigest: manifestDigest()}
}
func manifestDigest() string {
	b, e := os.ReadFile("adapter-manifest.json")
	if e != nil {
		return "sha256:" + strings.Repeat("0", 64)
	}
	h := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(h[:])
}
func (s *Server) Write(v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	if len(b) > MaxFrame {
		return errors.New("frame exceeds 8 MiB")
	}
	_, e = fmt.Fprintf(s.out, "%s\n", b)
	return e
}
func errResp(id any, c int, m string) Response {
	return Response{JSONRPC: "2.0", ID: id, Error: &RPCError{Code: c, Message: m}}
}
func (s *Server) Handle(r Request) Response {
	if r.JSONRPC != "2.0" {
		return errResp(r.ID, -32600, "invalid request")
	}
	switch r.Method {
	case "initialize":
		s.initialized = true
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"protocolVersion": "0.1", "adapterId": "com.menubarhome.tv-bridge", "adapterVersion": "1.0.0", "manifestDigest": s.manifestDigest, "capabilities": map[string]any{"readOnly": false, "commands": true}}}
	case "capabilities":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"readOnly": false, "deviceKinds": []string{"television", "mediaPlayer"}}}
	case "snapshot":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"capturedAt": "now", "devices": []any{}}}
	case "events.subscribe":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"subscriptionId": "sub-1", "acceptedTopics": []string{"stateChanged"}}}
	case "events.unsubscribe":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"ok": true}}
	case "health.ping":
		state := "ok"
		if s.sleeping {
			state = "offline"
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"state": state, "latencyMs": 0}}
	case "shutdown":
		s.quit = true
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"ok": true}}
	case "host.contextChanged":
		var p struct{ PanelVisible, SystemActive bool }
		if json.Unmarshal(r.Params, &p) == nil && (!p.PanelVisible || !p.SystemActive) {
			s.mu.Lock()
			s.sleeping = true
			s.mu.Unlock()
			debug.FreeOSMemory()
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"sleeping": s.sleeping}}
	case "control.execute":
		var p struct {
			GrantID              string         `json:"grantId"`
			CapabilityGeneration int64          `json:"capabilityGeneration"`
			Verb                 string         `json:"verb"`
			Args                 map[string]any `json:"args"`
		}
		if json.Unmarshal(r.Params, &p) != nil {
			return errResp(r.ID, -32602, "invalid params")
		}
		if p.GrantID == "" {
			return errResp(r.ID, -32004, "grantId required")
		}
		if p.CapabilityGeneration < s.generation {
			return errResp(r.ID, -32004, "stale capabilityGeneration")
		}
		allowed := map[string]bool{"tv.power": true, "tv.wake": true, "tv.screenOff": true, "media.setVolume": true, "media.stepVolume": true, "media.setMute": true, "media.selectSource": true, "media.launchApp": true, "media.playPause": true, "media.play": true, "media.pause": true, "media.stop": true, "media.next": true, "media.previous": true, "media.seek": true, "remote.key": true}
		if !allowed[p.Verb] {
			return errResp(r.ID, -32004, "unsupported verb")
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"accepted": true}}
	case "media.fetchArtwork":
		var p struct {
			Path string `json:"path"`
		}
		json.Unmarshal(r.Params, &p)
		clean := filepath.Clean(p.Path)
		root := filepath.Join(s.dataDir, "cache")
		full := filepath.Join(root, clean)
		if !strings.HasPrefix(full, root+string(os.PathSeparator)) {
			return errResp(r.ID, -32002, "path outside cache")
		}
		st, err := os.Stat(full)
		if err != nil {
			return errResp(r.ID, -32001, "artwork not found")
		}
		if st.Size() > 256*1024 {
			return errResp(r.ID, -32001, "artwork exceeds 256 KiB")
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"path": full}}
	case "pairing.begin", "pairing.submit", "pairing.cancel":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"ok": true}}
	default:
		return errResp(r.ID, -32601, "method not found")
	}
}
func (s *Server) Serve(in io.Reader) error {
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 64*1024), MaxFrame+1)
	for sc.Scan() {
		if len(sc.Bytes()) > MaxFrame {
			return errors.New("frame exceeds 8 MiB")
		}
		var r Request
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			_ = s.Write(errResp(nil, -32700, "parse error"))
			continue
		}
		if r.ID != nil {
			if e := s.Write(s.Handle(r)); e != nil {
				return e
			}
		}
		if s.quit {
			return nil
		}
	}
	return sc.Err()
}
