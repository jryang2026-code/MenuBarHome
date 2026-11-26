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

var (
	ErrUnsupported   = errors.New("unsupported")
	ErrInvalidParams = errors.New("invalid params")
	ErrDeviceOffline = errors.New("device offline")
	ErrUnreachable   = errors.New("unreachable")
)

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
	usedGrants     map[string]struct{}
	grantOrder     []string
}

func New(out io.Writer, dataDir string) *Server {
	return &Server{out: out, dataDir: dataDir, generation: 1, manifestDigest: manifestDigest(), devices: make(map[string]driver.TVDriver), usedGrants: make(map[string]struct{})}
}
func manifestDigest() string {
	paths := []string{}
	if p := os.Getenv("MBH_MANIFEST_PATH"); p != "" {
		paths = append(paths, p)
	}
	if exe, e := os.Executable(); e == nil {
		paths = append(paths, filepath.Join(filepath.Dir(exe), "adapter-manifest.json"))
	}
	paths = append(paths, "adapter-manifest.json")
	var b []byte
	var e error
	for _, p := range paths {
		b, e = os.ReadFile(p)
		if e == nil {
			break
		}
	}
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
			CapabilityGeneration int64    `json:"capabilityGeneration"`
			Supported            []string `json:"supportedProtocolVersions"`
			Config               struct {
				Devices []struct {
					NativeID string `json:"nativeId"`
					Driver   string `json:"driver"`
					Host     string `json:"host"`
					Port     int    `json:"port"`
					Name     string `json:"name"`
					MAC      string `json:"mac"`
				} `json:"devices"`
			} `json:"config"`
		}
		if err := json.Unmarshal(r.Params, &p); err != nil {
			return errResp(r.ID, -32602, "invalid params")
		}
		s.mu.Lock()
		if p.CapabilityGeneration > s.generation {
			s.generation = p.CapabilityGeneration
		}
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
		version, readOnly := "1.0", false
		for _, supported := range p.Supported {
			if supported == "0.1" {
				version, readOnly = "0.1", true
				break
			}
		}
		commands := []string{"tv.power", "tv.wake", "tv.screenOff", "media.setVolume", "media.stepVolume", "media.setMute", "media.selectSource", "media.launchApp", "media.playPause", "media.play", "media.pause", "media.stop", "media.next", "media.previous", "media.seek", "remote.key"}
		if readOnly {
			commands = []string{}
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"protocolVersion": version, "adapterId": "com.menubarhome.tv-bridge", "adapterVersion": "1.0.0", "manifestDigest": s.manifestDigest, "capabilities": map[string]any{"readOnly": readOnly, "deviceKinds": []string{"tv", "speaker"}, "commands": commands, "pushEvents": false}}}
	case "capabilities":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"readOnly": false, "deviceKinds": []string{"tv", "speaker"}}}
	case "snapshot":
		devices := make([]map[string]any, 0, len(s.devices))
		for nativeID, drv := range s.devices {
			snap, err := drv.Snapshot()
			if err != nil {
				devices = append(devices, map[string]any{"nativeId": nativeID, "name": nativeID, "kind": "tv", "online": false, "identity": map[string]any{"macAddresses": []string{}, "uniqueIds": []string{nativeID}}})
				continue
			}
			devices = append(devices, map[string]any{"nativeId": nativeID, "name": snap.Name, "kind": "tv", "online": true, "identity": map[string]any{"macAddresses": []string{}, "uniqueIds": []string{nativeID}}, "state": snap.Power, "volume": snap.Volume, "muted": snap.Muted, "source": snap.Source, "nowPlaying": snap.NowPlaying})
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"capturedAt": "now", "devices": devices}}
	case "events.subscribe":
		return errResp(r.ID, -32004, "unsupported")
	case "events.unsubscribe":
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"ok": true}}
	case "health.ping":
		state := "ok"
		if s.sleeping {
			state = "offline"
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"state": state, "latencyMs": 0}}
	case "shutdown":
		for _, drv := range s.devices {
			_ = drv.Close()
		}
		s.quit = true
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"ok": true}}
	case "host.contextChanged":
		var p struct {
			PanelVisible, SystemActive bool
			CapabilityGeneration       int64 `json:"capabilityGeneration"`
		}
		if json.Unmarshal(r.Params, &p) == nil {
			s.mu.Lock()
			if p.CapabilityGeneration > s.generation {
				s.generation = p.CapabilityGeneration
			}
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
		if p.CapabilityGeneration != s.generation {
			return errResp(r.ID, -32004, "unknown capabilityGeneration")
		}
		allowed := map[string]bool{"tv.power": true, "tv.wake": true, "tv.screenOff": true, "media.setVolume": true, "media.stepVolume": true, "media.setMute": true, "media.selectSource": true, "media.launchApp": true, "media.playPause": true, "media.play": true, "media.pause": true, "media.stop": true, "media.next": true, "media.previous": true, "media.seek": true, "remote.key": true}
		if !allowed[p.Verb] {
			return errResp(r.ID, -32004, "unsupported verb")
		}
		s.mu.Lock()
		if _, exists := s.usedGrants[p.GrantID]; exists {
			s.mu.Unlock()
			return errResp(r.ID, -32004, "grantId replayed")
		}
		s.usedGrants[p.GrantID] = struct{}{}
		s.grantOrder = append(s.grantOrder, p.GrantID)
		if len(s.grantOrder) > 1024 {
			delete(s.usedGrants, s.grantOrder[0])
			s.grantOrder = s.grantOrder[1:]
		}
		s.mu.Unlock()
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
		if err := json.Unmarshal(r.Params, &p); err != nil {
			return errResp(r.ID, -32602, "invalid params")
		}
		clean := filepath.Clean(p.Path)
		root := filepath.Join(s.dataDir, "cache")
		full := filepath.Join(root, clean)
		realRoot, err := filepath.EvalSymlinks(root)
		if err != nil {
			return errResp(r.ID, -32002, "cache unavailable")
		}
		realFull, err := filepath.EvalSymlinks(full)
		if os.IsNotExist(err) {
			parent, parentErr := filepath.EvalSymlinks(filepath.Dir(full))
			if parentErr != nil {
				return errResp(r.ID, -32002, "artwork unavailable")
			}
			realFull = filepath.Join(parent, filepath.Base(full))
		} else if err != nil {
			return errResp(r.ID, -32002, "artwork unavailable")
		}
		if !strings.HasPrefix(realFull, realRoot+string(os.PathSeparator)) {
			return errResp(r.ID, -32002, "path outside cache")
		}
		st, err := os.Stat(realFull)
		if err != nil {
			return errResp(r.ID, -32001, "artwork not found")
		}
		if st.Size() > 256*1024 {
			return errResp(r.ID, -32001, "artwork exceeds 256 KiB")
		}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"path": realFull}}
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
