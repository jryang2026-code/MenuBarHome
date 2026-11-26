package rpc

import (
	"bufio"
	"com.menubarhome.tv-bridge/internal/driver"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
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
	devices        map[string]driver.TVDriver
}

func New(out io.Writer, dataDir string) *Server {
	return &Server{out: out, dataDir: dataDir, generation: 1, manifestDigest: manifestDigest(), devices: make(map[string]driver.TVDriver)}
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
		var p struct {
			Config struct {
				Devices []struct {
					NativeID string `json:"nativeId"`
					Driver   string `json:"driver"`
					Host     string `json:"host"`
					Port     int    `json:"port"`
				} `json:"devices"`
			} `json:"config"`
		}
		if err := json.Unmarshal(r.Params, &p); err != nil {
			return errResp(r.ID, -32602, "invalid params")
		}
		s.mu.Lock()
		s.initialized = true
		for _, d := range p.Config.Devices {
			if d.NativeID == "" || d.Host == "" {
				continue
			}
			addr := d.Host
			if d.Port > 0 {
				addr = net.JoinHostPort(d.Host, fmt.Sprint(d.Port))
			}
			if drv := driver.ForID(d.Driver, addr); drv != nil {
				s.devices[d.NativeID] = drv
			}
		}
		s.mu.Unlock()
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"protocolVersion": "1.0", "adapterId": "com.menubarhome.tv-bridge", "adapterVersion": "1.0.0", "manifestDigest": s.manifestDigest, "capabilities": map[string]any{"readOnly": false, "commands": true}}}
	case "capabilities":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"readOnly": false, "deviceKinds": []string{"tv", "speaker"}}}
	case "snapshot":
		devices := make([]map[string]any, 0, len(s.devices))
		for nativeID, drv := range s.devices {
			snap, err := drv.Snapshot()
			if err != nil {
				devices = append(devices, map[string]any{"nativeId": nativeID, "offline": true})
				continue
			}
			devices = append(devices, map[string]any{"nativeId": nativeID, "snapshot": snap})
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"capturedAt": "now", "devices": devices}}
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
		if json.Unmarshal(r.Params, &p) == nil {
			s.mu.Lock()
			s.sleeping = !p.PanelVisible || !p.SystemActive
			sleeping := s.sleeping
			s.mu.Unlock()
			if sleeping {
				for _, drv := range s.devices {
					_ = drv.Sleep()
				}
				debug.FreeOSMemory()
			}
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"sleeping": s.sleeping}}
	case "control.execute":
		var p struct {
			NativeID             string         `json:"nativeId"`
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
		drv, ok := s.devices[p.NativeID]
		if !ok {
			return errResp(r.ID, -32005, "device unavailable")
		}
		if err := drv.Execute(p.Verb, p.Args); err != nil {
			if strings.Contains(err.Error(), "unsupported") || strings.Contains(err.Error(), "invalid") {
				return errResp(r.ID, -32004, err.Error())
			}
			return errResp(r.ID, -32002, err.Error())
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
