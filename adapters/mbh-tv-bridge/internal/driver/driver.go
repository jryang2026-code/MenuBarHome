package driver

import (
	"bytes"
	"com.menubarhome.tv-bridge/internal/ws"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Snapshot struct {
	ID         string      `json:"id"`
	Name       string      `json:"name"`
	Power      string      `json:"power,omitempty"`
	Volume     int         `json:"volume,omitempty"`
	Muted      bool        `json:"muted,omitempty"`
	Source     string      `json:"source,omitempty"`
	NowPlaying *NowPlaying `json:"nowPlaying,omitempty"`
}
type NowPlaying struct {
	State             string  `json:"state,omitempty"`
	Title             string  `json:"title,omitempty"`
	Subtitle          string  `json:"subtitle,omitempty"`
	AppName           string  `json:"appName,omitempty"`
	ArtworkURI        string  `json:"artworkURL,omitempty"`
	DurationSec       float64 `json:"durationSec,omitempty"`
	PositionSec       float64 `json:"positionSec,omitempty"`
	PositionUpdatedAt string  `json:"positionUpdatedAt,omitempty"`
	PlaybackRate      float64 `json:"playbackRate,omitempty"`
	CanPlayPause      bool    `json:"canPlayPause,omitempty"`
	CanSeek           bool    `json:"canSeek,omitempty"`
	CanSkipTrack      bool    `json:"canSkipTrack,omitempty"`
}
type TVDriver interface {
	ID() string
	Probe() error
	Snapshot() (Snapshot, error)
	Execute(string, map[string]any) error
	Sleep() error
	Close() error
}

type MACSetter interface{ SetMAC(string) }
type Base struct {
	id, addr string
	client   *http.Client
	mu       sync.Mutex
	sleeping bool
}

func ensureHTTPBase(addr string) string {
	if strings.HasPrefix(addr, "http://") || strings.HasPrefix(addr, "https://") {
		return strings.TrimRight(addr, "/")
	}
	return "http://" + strings.TrimRight(addr, "/")
}

func (b *Base) ID() string     { return b.id }
func (b *Base) Sleep() error   { b.mu.Lock(); b.sleeping = true; b.mu.Unlock(); return nil }
func (b *Base) Close() error   { return nil }
func httpClient() *http.Client { return &http.Client{Timeout: 5 * time.Second} }
func sameOriginHTTPClient() *http.Client {
	client := httpClient()
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		origin := via[0].URL
		if req.URL.Scheme != origin.Scheme || !strings.EqualFold(req.URL.Host, origin.Host) {
			return errors.New("cross-origin TV redirect refused")
		}
		if len(via) >= 10 {
			return errors.New("too many TV redirects")
		}
		return nil
	}
	return client
}
func getJSON(c *http.Client, u string, out any) error {
	r, e := c.Get(u)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(out)
}
func postJSON(c *http.Client, u string, v any, out any) error {
	b, _ := json.Marshal(v)
	r, e := c.Post(u, "application/json", bytes.NewReader(b))
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(out)
	}
	return nil
}
var ClosedCommandVerbs = []string{"power.set", "power.wake", "power.screenOff", "volume.set", "mute.set", "input.select", "remote.key", "media.playPause", "media.play", "media.pause", "media.stop", "media.next", "media.previous", "media.seek"}
var RegisteredDrivers = []string{"lg_webos_ssap", "xiaomi_mitv_6095", "hisense_vidaa_mqtt", "samsung_tizen_ws", "sony_bravia_psk", "tcl_ffalcon_tnscreen", "android_adb_lan", "dlna_dmr", "kodi_jsonrpc"}

func IsAllowedVerb(verb string) bool {
	for _, v := range ClosedCommandVerbs {
		if v == verb {
			return true
		}
	}
	return false
}
func argVal(a map[string]any, keys ...string) (any, bool) {
	for _, k := range keys {
		if v, ok := a[k]; ok {
			return v, true
		}
	}
	return nil, false
}

func commandAllowed(verb string, args map[string]any) error {
	if !IsAllowedVerb(verb) {
		return fmt.Errorf("unsupported verb %q", verb)
	}
	if verb == "remote.key" {
		k, _ := args["key"].(string)
		keys := map[string]bool{"up": true, "down": true, "left": true, "right": true, "select": true, "back": true, "home": true, "menu": true, "volumeUp": true, "volumeDown": true, "mute": true, "source": true, "channelUp": true, "channelDown": true, "playPause": true, "info": true}
		if !keys[k] {
			return fmt.Errorf("unsupported remote key")
		}
	}
	return nil
}

func clampInt(v, lo, hi int) int { if v < lo { return lo }; if v > hi { return hi }; return v }
func parseVolumeLevel(a map[string]any) (int, error) {
	raw, ok := argVal(a, "level", "volume")
	f, err := strconv.ParseFloat(fmt.Sprint(raw), 64)
	if !ok || err != nil || math.IsNaN(f) || math.IsInf(f, 0) || f < 0 || f > 100 { return 0, errors.New("invalid volume") }
	return int(math.Round(f)), nil
}
func parseBoolArg(a map[string]any, keys ...string) (bool, error) {
	raw, ok := argVal(a, keys...); b, bOk := raw.(bool)
	if !ok || !bOk { return false, errors.New("invalid boolean argument") }
	return b, nil
}
func sanitizeErr(err error, secrets ...string) error {
	if err == nil { return nil }
	msg := err.Error()
	for _, s := range secrets { if s = strings.TrimSpace(s); len(s) >= 2 { msg = strings.ReplaceAll(msg, s, "[REDACTED]") } }
	return errors.New(msg)
}

type Xiaomi struct{ Base }

func NewXiaomi(addr string) *Xiaomi { return &Xiaomi{Base: Base{id: "xiaomi_mitv_6095", addr: ensureHTTPBase(addr), client: sameOriginHTTPClient()}} }
func (d *Xiaomi) aliveInfo() (string, error) {
	var r struct{ Status *int; Data struct{ DeviceName string } }
	if err := getJSON(d.client, d.addr+"/request?action=isalive", &r); err != nil { return "", err }
	if r.Status != nil && *r.Status != 0 { return "", fmt.Errorf("xiaomi isalive status %d", *r.Status) }
	if name := strings.TrimSpace(r.Data.DeviceName); name != "" { return name, nil }
	return "Xiaomi TV", nil
}
func (d *Xiaomi) Probe() error { _, err := d.aliveInfo(); return err }
func (d *Xiaomi) getVolumeState() (cur, maxVol int, muted, hasMuted bool, err error) {
	var r struct {
		Volume, MaxVolume *int; Muted *bool
		Data struct{ Volum, MaxVolum, Volume, MaxVolume *int; Muted *bool }
	}
	if err = getJSON(d.client, d.addr+"/general?action=getvolume", &r); err != nil { return 0, 100, false, false, err }
	if r.Data.Muted != nil { muted, hasMuted = *r.Data.Muted, true } else if r.Muted != nil { muted, hasMuted = *r.Muted, true }
	switch {
	case r.Data.Volum != nil: cur, maxVol = *r.Data.Volum, 15; if r.Data.MaxVolum != nil && *r.Data.MaxVolum > 0 { maxVol = *r.Data.MaxVolum }
	case r.Data.Volume != nil: cur, maxVol = *r.Data.Volume, 100; if r.Data.MaxVolume != nil && *r.Data.MaxVolume > 0 { maxVol = *r.Data.MaxVolume }
	case r.Volume != nil: cur, maxVol = *r.Volume, 100; if r.MaxVolume != nil && *r.MaxVolume > 0 { maxVol = *r.MaxVolume }
	default: return 0, 100, muted, hasMuted, errors.New("xiaomi getvolume missing volume field")
	}
	return clampInt(cur, 0, maxVol), maxVol, muted, hasMuted, nil
}
func (d *Xiaomi) Snapshot() (Snapshot, error) {
	name, err := d.aliveInfo(); if err != nil { return Snapshot{}, err }
	snap := Snapshot{ID: d.id, Name: name, Power: "on"}
	if cur, maxVol, muted, _, vErr := d.getVolumeState(); vErr == nil && maxVol > 0 {
		snap.Volume, snap.Muted = clampInt(int(math.Round(float64(cur)*100.0/float64(maxVol))), 0, 100), muted
	}
	return snap, nil
}
func (d *Xiaomi) getControl(ctx context.Context, path string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.addr+path, nil)
	if err != nil {
		return err
	}
	r, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	_, err = io.Copy(io.Discard, io.LimitReader(r.Body, 64<<10))
	return err
}
func (d *Xiaomi) sendKey(ctx context.Context, code string) error {
	return d.getControl(ctx, "/controller?action=keyevent&keycode=" + url.QueryEscape(code))
}
func (d *Xiaomi) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil { return e }
	ctx := context.Background()
	switch v {
	case "power.set":
		isOn, err := parseBoolArg(a, "isOn"); if err != nil { return err }
		alive := d.Probe() == nil
		if isOn { if alive { return nil }; return errors.New("xiaomi tv offline; cold wake unavailable") }
		if !alive { return nil }; return d.sendKey(ctx, "power")
	case "volume.set":
		level, err := parseVolumeLevel(a); if err != nil { return err }
		cur, maxVol, _, _, err := d.getVolumeState(); if err != nil { return err }
		target := maxVol
		if level < 100 {
			target = int(math.Round(float64(level) * float64(maxVol) / 100.0))
		}
		diff := target - cur
		code := "volumeup"; if diff < 0 { code, diff = "volumedown", -diff }
		if diff > 100 {
			return errors.New("xiaomi volume target requires more than 100 key presses")
		}
		ctx, cancel := context.WithTimeout(ctx, d.client.Timeout)
		defer cancel()
		for step := range diff {
			if err := d.sendKey(ctx, code); err != nil {
				return fmt.Errorf("xiaomi volume target incomplete after %d of %d key presses: %w", step, diff, err)
			}
		}
		return nil
	case "mute.set":
		desired, err := parseBoolArg(a, "isMuted", "muted"); if err != nil { return err }
		if _, _, curMuted, hasMuted, err := d.getVolumeState(); err == nil && hasMuted && curMuted == desired { return nil }
		return d.sendKey(ctx, "mute")
	case "input.select":
		s, _ := a["source"].(string); src := strings.ToLower(strings.NewReplacer(" ", "", "_", "").Replace(strings.TrimSpace(s)))
		if !map[string]bool{"hdmi1": true, "hdmi2": true, "hdmi3": true, "hdmi4": true, "av": true, "dtmb": true, "atv": true, "vga": true}[src] { return errors.New("invalid source") }
		return d.getControl(ctx, "/controller?action=changesource&source=" + url.QueryEscape(src))
	case "remote.key":
		code, ok := map[string]string{"up": "up", "down": "down", "left": "left", "right": "right", "select": "enter", "back": "back", "home": "home", "menu": "menu", "volumeUp": "volumeup", "volumeDown": "volumedown", "mute": "mute", "source": "source", "channelUp": "channelup", "channelDown": "channeldown", "playPause": "playpause", "info": "info"}[fmt.Sprint(a["key"])]
		if !ok { return errors.New("unsupported remote key") }
		return d.sendKey(ctx, code)
	case "media.playPause", "media.play", "media.pause", "media.stop", "media.next", "media.previous":
		return d.sendKey(ctx, map[string]string{"media.playPause": "playpause", "media.play": "play", "media.pause": "pause", "media.stop": "stop", "media.next": "next", "media.previous": "previous"}[v])
	default: return errors.New("unsupported Xiaomi action")
	}
}

type Sony struct {
	Base
	PSK string
}

func NewSony(addr, psk string) *Sony {
	return &Sony{Base: Base{id: "sony_bravia_psk", addr: ensureHTTPBase(addr), client: sameOriginHTTPClient()}, PSK: psk}
}
func (d *Sony) do(req *http.Request) (*http.Response, error) {
	if d.PSK != "" {
		req.Header.Set("X-Auth-PSK", d.PSK)
	}
	return d.client.Do(req)
}
func (d *Sony) Probe() error {
	req, e := http.NewRequest("GET", d.addr+"/sony/system", nil)
	if e != nil {
		return e
	}
	r, e := d.do(req)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return nil
}
func (d *Sony) Snapshot() (Snapshot, error) {
	b, _ := json.Marshal(map[string]any{"method": "getPowerStatus", "params": []any{}, "id": 1, "version": "1.0"})
	req, er := http.NewRequest("POST", d.addr+"/sony/system", bytes.NewReader(b))
	if er != nil {
		return Snapshot{}, er
	}
	req.Header.Set("Content-Type", "application/json")
	r, er := d.do(req)
	if er != nil {
		return Snapshot{}, er
	}
	defer r.Body.Close()
	var x any
	var e error
	if r.StatusCode >= 300 {
		e = fmt.Errorf("http status %s", r.Status)
	} else {
		e = json.NewDecoder(r.Body).Decode(&x)
	}
	return Snapshot{ID: d.id, Name: "Sony Bravia"}, e
}
func (d *Sony) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	method := ""
	path := "/sony/system"
	params := []any{}
	switch v {
	case "power.set":
		status := true
		if b, ok := a["isOn"].(bool); ok {
			status = b
		}
		method = "setPowerStatus"
		params = []any{map[string]any{"status": status}}
	case "power.screenOff":
		method = "setPowerStatus"
		params = []any{map[string]any{"status": false}}
	case "volume.set":
		vol, _ := argVal(a, "level", "volume")
		path = "/sony/audio"
		method = "setAudioVolume"
		params = []any{map[string]any{"volume": fmt.Sprint(vol)}}
	case "mute.set":
		muted, _ := argVal(a, "isMuted", "muted")
		path = "/sony/audio"
		method = "setAudioMute"
		params = []any{map[string]any{"status": muted}}
	default:
		return errors.New("unsupported Sony action")
	}
	b, _ := json.Marshal(map[string]any{"method": method, "params": params, "id": 1, "version": "1.0"})
	req, e := http.NewRequest("POST", d.addr+path, bytes.NewReader(b))
	if e != nil {
		return e
	}
	req.Header.Set("Content-Type", "application/json")
	r, e := d.do(req)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return nil
}

type Kodi struct{ Base }

func NewKodi(addr string) *Kodi {
	return &Kodi{Base: Base{id: "kodi_jsonrpc", addr: ensureHTTPBase(addr), client: httpClient()}}
}
func (d *Kodi) Probe() error {
	var x any
	return postJSON(d.client, d.addr+"/jsonrpc", map[string]any{"jsonrpc": "2.0", "method": "JSONRPC.Ping", "id": 1}, &x)
}
func (d *Kodi) Snapshot() (Snapshot, error) {
	var x struct {
		Result []map[string]any `json:"result"`
	}
	e := postJSON(d.client, d.addr+"/jsonrpc", map[string]any{"jsonrpc": "2.0", "method": "Player.GetActivePlayers", "id": 1}, &x)
	return Snapshot{ID: d.id, Name: "Kodi"}, e
}
func (d *Kodi) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	methods := map[string]string{"media.playPause": "Player.PlayPause", "media.play": "Player.PlayPause", "media.pause": "Player.PlayPause", "media.stop": "Player.Stop", "media.next": "Player.GoNext", "media.previous": "Player.GoPrevious", "media.seek": "Player.Seek", "volume.set": "Application.SetVolume", "remote.key": "Input.ExecuteAction"}
	method, ok := methods[v]
	if !ok {
		return errors.New("unsupported Kodi action")
	}
	params := map[string]any{"playerid": 1}
	if v == "media.play" {
		params["play"] = true
	}
	if v == "media.pause" {
		params["play"] = false
	}
	if v == "media.playPause" {
		params["play"] = "toggle"
	}
	if v == "remote.key" {
		params["action"] = a["key"]
	}
	if v == "media.seek" {
		pos, _ := argVal(a, "positionSec", "position")
		params["playerid"] = 1
		params["value"] = pos
	}
	if v == "volume.set" {
		vol, _ := argVal(a, "level", "volume")
		params["volume"] = vol
	}
	var result struct {
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := postJSON(d.client, d.addr+"/jsonrpc", map[string]any{"jsonrpc": "2.0", "method": method, "params": params, "id": 1}, &result); err != nil {
		return err
	}
	if result.Error != nil {
		return fmt.Errorf("kodi error %d: %s", result.Error.Code, result.Error.Message)
	}
	return nil
}

type DLNA struct{ Base }

func NewDLNA(addr string) *DLNA {
	return &DLNA{Base: Base{id: "dlna_dmr", addr: ensureHTTPBase(addr), client: httpClient()}}
}
func (d *DLNA) Probe() error {
	req, e := http.NewRequest("POST", d.addr, strings.NewReader("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body/></s:Envelope>"))
	if e != nil {
		return e
	}
	req.Header.Set("SOAPACTION", "\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\"")
	r, e := d.client.Do(req)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return nil
}
func (d *DLNA) Snapshot() (Snapshot, error) {
	return Snapshot{ID: d.id, Name: "DLNA Renderer"}, d.Probe()
}
func (d *DLNA) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	action := map[string]string{"media.play": "Play", "media.pause": "Pause", "media.stop": "Stop", "media.seek": "Seek"}[v]
	if action == "" {
		return errors.New("unsupported DLNA action")
	}
	args := "<InstanceID>0</InstanceID>"
	if action == "Seek" {
		pos, _ := argVal(a, "positionSec", "position")
		seconds, _ := strconv.ParseFloat(fmt.Sprint(pos), 64)
		total := int(seconds)
		args += fmt.Sprintf("<Unit>REL_TIME</Unit><Target>%02d:%02d:%02d</Target>", total/3600, (total/60)%60, total%60)
	}
	body := fmt.Sprintf("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:%s xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">%s</u:%s></s:Body></s:Envelope>", action, args, action)
	req, e := http.NewRequest("POST", d.addr, strings.NewReader(body))
	if e != nil {
		return e
	}
	req.Header.Set("SOAPACTION", fmt.Sprintf("\"urn:schemas-upnp-org:service:AVTransport:1#%s\"", action))
	r, e := d.client.Do(req)
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return nil
}

type TCL struct {
	Base
	conn    net.Conn
	key, iv []byte
}

func (d *TCL) Sleep() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.sleeping = true
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	return nil
}
func (d *TCL) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	return nil
}

func NewTCL(addr string) *TCL {
	return &TCL{Base: Base{id: "tcl_ffalcon_tnscreen", addr: addr, client: httpClient(), sleeping: false}, key: []byte("tnscreentnscreen"), iv: []byte{0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef}}
}
func pad(b []byte) []byte {
	n := aes.BlockSize - len(b)%aes.BlockSize
	return append(b, bytes.Repeat([]byte{byte(n)}, n)...)
}
func unpad(b []byte) ([]byte, error) {
	if len(b) == 0 || len(b)%aes.BlockSize != 0 {
		return nil, errors.New("invalid padding")
	}
	n := int(b[len(b)-1])
	if n < 1 || n > aes.BlockSize || n > len(b) {
		return nil, errors.New("invalid padding")
	}
	for _, x := range b[len(b)-n:] {
		if int(x) != n {
			return nil, errors.New("invalid padding")
		}
	}
	return b[:len(b)-n], nil
}
func (d *TCL) Encrypt(p []byte) ([]byte, error) {
	c, e := aes.NewCipher(d.key)
	if e != nil {
		return nil, e
	}
	o := make([]byte, len(pad(p)))
	cipher.NewCBCEncrypter(c, d.iv).CryptBlocks(o, pad(p))
	return o, nil
}
func (d *TCL) Decrypt(p []byte) ([]byte, error) {
	c, e := aes.NewCipher(d.key)
	if e != nil {
		return nil, e
	}
	if len(p)%16 != 0 {
		return nil, errors.New("invalid ciphertext")
	}
	o := make([]byte, len(p))
	cipher.NewCBCDecrypter(c, d.iv).CryptBlocks(o, p)
	return unpad(o)
}
func (d *TCL) Probe() error {
	c, e := net.DialTimeout("tcp", d.addr, 3*time.Second)
	if e != nil {
		return e
	}
	d.conn = c
	_, e = c.Write([]byte("159"))
	return e
}
func (d *TCL) Snapshot() (Snapshot, error) {
	d.mu.Lock()
	active := d.conn != nil
	d.mu.Unlock()
	if !active {
		if e := d.Probe(); e != nil {
			return Snapshot{}, e
		}
	}
	return Snapshot{ID: d.id, Name: "TCL/FFALCON"}, nil
}
func (d *TCL) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	if d.conn == nil {
		if e := d.Probe(); e != nil {
			return e
		}
	}
	codes := map[string]string{"up": "11", "down": "12", "left": "13", "right": "14", "select": "15", "back": "16", "home": "19", "source": "29", "volumeUp": "31", "volumeDown": "32"}
	k := fmt.Sprint(a["key"])
	if v == "power.set" {
		k = "power"
	}
	if k == "power" {
		codes["power"] = "20"
	}
	code, ok := codes[k]
	if !ok {
		return errors.New("unsupported TCL key")
	}
	enc, e := d.Encrypt([]byte("149>>" + code))
	if e != nil {
		return e
	}
	_, e = d.conn.Write(enc)
	return e
}

type AndroidADB struct {
	Base
	mu      sync.Mutex
	conn    net.Conn
	localID uint32
}

func adbChecksum(p []byte) uint32 {
	var sum uint32
	for _, b := range p {
		sum += uint32(b)
	}
	return sum
}

func (d *AndroidADB) Sleep() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	d.sleeping = true
	return nil
}
func (d *AndroidADB) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	return nil
}

func NewAndroidADB(addr string) *AndroidADB {
	return &AndroidADB{Base: Base{id: "android_adb_lan", addr: addr, client: httpClient(), sleeping: false}}
}
func (d *AndroidADB) Probe() error {
	d.mu.Lock()
	if d.conn != nil {
		_ = d.conn.Close()
		d.conn = nil
	}
	d.mu.Unlock()
	c, e := net.DialTimeout("tcp", d.addr, 2*time.Second)
	if e == nil {
		d.mu.Lock()
		d.conn = c
		d.mu.Unlock()
		h := make([]byte, 24)
		binary.LittleEndian.PutUint32(h[0:4], 0x4e584e43)
		binary.LittleEndian.PutUint32(h[4:8], 0x01000000)
		payload := []byte("host::\x00")
		binary.LittleEndian.PutUint32(h[12:16], uint32(len(payload)))
		binary.LittleEndian.PutUint32(h[16:20], adbChecksum(payload))
		binary.LittleEndian.PutUint32(h[20:24], 0x4e584e43^0xffffffff)
		if _, e = c.Write(append(h, payload...)); e != nil {
			_ = c.Close()
			d.mu.Lock()
			d.conn = nil
			d.mu.Unlock()
			return e
		}
	}
	return e
}
func (d *AndroidADB) Snapshot() (Snapshot, error) {
	d.mu.Lock()
	active := d.conn != nil
	d.mu.Unlock()
	if !active {
		if e := d.Probe(); e != nil {
			return Snapshot{}, e
		}
	}
	return Snapshot{ID: d.id, Name: "Android TV"}, nil
}
func (d *AndroidADB) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	k := fmt.Sprint(a["key"])
	allowed := map[string]bool{"up": true, "down": true, "left": true, "right": true, "select": true, "back": true, "home": true, "volumeUp": true, "volumeDown": true, "mute": true, "power": true}
	if v == "remote.key" && !allowed[k] {
		return errors.New("unsafe adb key")
	}
	if d.conn == nil {
		if e := d.Probe(); e != nil {
			return e
		}
	}
	codes := map[string]uint32{"up": 19, "down": 20, "left": 21, "right": 22, "select": 23, "back": 4, "home": 3, "menu": 82, "volumeUp": 24, "volumeDown": 25, "mute": 164, "power": 26}
	code, ok := codes[k]
	if !ok {
		return errors.New("unsafe adb key")
	}
	payload := []byte(fmt.Sprintf("shell:input keyevent %d\x00", code))
	hdr := make([]byte, 24)
	binary.LittleEndian.PutUint32(hdr[0:4], 0x4e45504f)
	d.localID++
	if d.localID == 0 {
		d.localID = 1
	}
	binary.LittleEndian.PutUint32(hdr[4:8], d.localID)
	binary.LittleEndian.PutUint32(hdr[12:16], uint32(len(payload)))
	binary.LittleEndian.PutUint32(hdr[16:20], adbChecksum(payload))
	binary.LittleEndian.PutUint32(hdr[20:24], 0x4e45504f^0xffffffff)
	if _, e := d.conn.Write(append(hdr, payload...)); e != nil {
		_ = d.conn.Close()
		d.conn = nil
		return e
	}
	return nil
}

type LG struct {
	Base
	TLS          bool
	ClientKey    string
	MAC, wolTarget       string
	Timeout, PairTimeout time.Duration
	mediaMu              sync.Mutex
	mediaPlaying         bool
	trustMu              sync.Mutex
	fingerprint          string
	pairingPath          string
}

func NewLG(addr string, tlsOn bool) *LG {
	return &LG{Base: Base{id: "lg_webos_ssap", addr: addr, client: httpClient(), sleeping: false}, TLS: tlsOn}
}

type HisenseVIDAA struct {
	Base
	Credential string
	Timeout    time.Duration
	Plaintext  bool
	muted      bool
	playing    bool
}

func NewHisenseVIDAA(addr, credential string) *HisenseVIDAA {
	return &HisenseVIDAA{Base: Base{id: "hisense_vidaa_mqtt", addr: addr, client: httpClient(), sleeping: false}, Credential: credential}
}
func mqttStr(s string) ([]byte, error) {
	if len(s) > 0xffff { return nil, errors.New("mqtt string too long") }
	b := make([]byte, 2+len(s))
	binary.BigEndian.PutUint16(b[:2], uint16(len(s)))
	copy(b[2:], s)
	return b, nil
}
func mqttPacket(hdr byte, body []byte) []byte {
	n := len(body)
	var rem []byte
	for {
		b := byte(n % 128)
		n /= 128
		if n > 0 {
			b |= 0x80
		}
		rem = append(rem, b)
		if n == 0 {
			break
		}
	}
	out := make([]byte, 0, 1+len(rem)+len(body))
	return append(append(append(out, hdr), rem...), body...)
}
func (d *HisenseVIDAA) mqttCreds() (string, string) {
	const defaultUser = "hisenseservice"
	if d.Credential == "" {
		return defaultUser, "multimqttservice"
	}
	if u, p, ok := strings.Cut(d.Credential, ":"); ok {
		return u, p
	}
	return defaultUser, d.Credential
}
func (d *HisenseVIDAA) mqttDo(topic, payload string) error {
	target := d.addr
	if _, _, err := net.SplitHostPort(target); err != nil {
		target = net.JoinHostPort(target, "36669")
	}
	user, pass := d.mqttCreds()
	redact := func(err error) error { if d.Credential == "" { return err }; return sanitizeErr(err, d.Credential, user, pass) }
	budget := 5 * time.Second; if d.Timeout > 0 { budget = d.Timeout }
	deadline := time.Now().Add(budget)
	dl := &net.Dialer{Timeout: budget, Deadline: deadline}
	raw, err := dl.Dial("tcp", target)
	if err != nil { return redact(err) }
	_ = raw.SetDeadline(deadline)
	c := raw
	if !d.Plaintext {
		tlsConn := tls.Client(raw, &tls.Config{InsecureSkipVerify: true})
		if err := tlsConn.Handshake(); err == nil {
			c = tlsConn
		} else {
			_ = raw.Close()
			var headerErr tls.RecordHeaderError
			if !errors.As(err, &headerErr) || headerErr.Conn == nil {
				return redact(err)
			}
			c, err = dl.Dial("tcp", target)
			if err != nil { return redact(err) }
			_ = c.SetDeadline(deadline)
		}
	}
	defer c.Close()
	connBody := []byte{0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0xC2, 0x00, 0x1E}
	for _, f := range []string{"menubarhome-tv", user, pass} { enc, err := mqttStr(f); if err != nil { return redact(err) }; connBody = append(connBody, enc...) }
	if _, err := c.Write(mqttPacket(0x10, connBody)); err != nil { return redact(err) }
	var ack [4]byte
	if _, err := io.ReadFull(c, ack[:]); err != nil { return redact(err) }
	if ack[0] != 0x20 || ack[1] != 0x02 { return errors.New("invalid mqtt connack") }
	if ack[3] != 0x00 { return fmt.Errorf("mqtt connack refused (%d)", ack[3]) }
	if topic != "" {
		tEnc, err := mqttStr(topic); if err != nil { return redact(err) }
		if _, err := c.Write(mqttPacket(0x30, append(tEnc, payload...))); err != nil { return redact(err) }
	}
	_, _ = c.Write([]byte{0xE0, 0x00})
	return nil
}
func (d *HisenseVIDAA) Probe() error {
	return d.mqttDo("", "")
}
func (d *HisenseVIDAA) Snapshot() (Snapshot, error) {
	if err := d.Probe(); err != nil { return Snapshot{}, err }
	return Snapshot{ID: d.id, Name: "Hisense VIDAA", Power: "on"}, nil
}
func (d *HisenseVIDAA) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	const keyTopic = "/remoteapp/tv/remote_service/menubarhome$normal/actions/sendkey"
	switch v {
	case "power.set":
		isOn, err := parseBoolArg(a, "isOn"); if err != nil { return err }
		if isOn { return d.Probe() }
		return d.mqttDo(keyTopic, "KEY_POWER")
	case "mute.set":
		muted, err := parseBoolArg(a, "isMuted", "muted"); if err != nil { return err }
		if muted == d.muted { return nil }
		if err := d.mqttDo(keyTopic, "KEY_MUTE"); err != nil { return err }
		d.muted = muted
		return nil
	case "volume.set":
		vol, err := parseVolumeLevel(a); if err != nil { return err }
		return d.mqttDo("/remoteapp/tv/platform_service/menubarhome$normal/actions/changevolume", strconv.Itoa(vol))
	case "input.select":
		s, _ := a["source"].(string)
		s = strings.TrimSpace(s)
		if s == "" {
			return errors.New("invalid source")
		}
		b, _ := json.Marshal(map[string]string{"sourceid": s, "sourcename": s})
		return d.mqttDo("/remoteapp/tv/ui_service/menubarhome$normal/actions/changesource", string(b))
	case "media.play", "media.pause", "media.stop", "media.playPause":
		return d.sendMediaKey(keyTopic, v)
	case "remote.key":
		key, _ := a["key"].(string)
		if key == "playPause" { return d.sendMediaKey(keyTopic, "media.playPause") }
		keys := map[string]string{"up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT", "select": "KEY_OK", "back": "KEY_RETURNS", "home": "KEY_HOME", "menu": "KEY_MENU", "volumeUp": "KEY_VOLUMEUP", "volumeDown": "KEY_VOLUMEDOWN", "mute": "KEY_MUTE", "source": "KEY_SOURCE", "channelUp": "KEY_CHANNELUP", "channelDown": "KEY_CHANNELDOWN", "info": "KEY_INFO"}
		code, ok := keys[key]
		if !ok {
			return errors.New("unsupported Hisense key")
		}
		if err := d.mqttDo(keyTopic, code); err != nil { return err }
		if key == "mute" { d.muted = !d.muted }
		return nil
	default:
		return errors.New("unsupported Hisense VIDAA action")
	}
}

func (d *HisenseVIDAA) sendMediaKey(topic, verb string) error {
	playing := verb == "media.play" || (verb == "media.playPause" && !d.playing)
	key := "KEY_PAUSE"
	if playing {
		key = "KEY_PLAY"
	} else if verb == "media.stop" {
		key = "KEY_STOP"
	}
	if err := d.mqttDo(topic, key); err != nil { return err }
	d.playing = playing
	return nil
}

func ForID(id, addr string) TVDriver {
	switch id {
	case "xiaomi_mitv_6095":
		return NewXiaomi(addr)
	case "tcl_ffalcon_tnscreen":
		return NewTCL(addr)
	case "android_adb_lan":
		return NewAndroidADB(addr)
	case "lg_webos_ssap":
		return NewLG(addr, true)
	case "hisense_vidaa_mqtt":
		return NewHisenseVIDAA(addr, "")
	case "sony_bravia_psk":
		return NewSony(addr, "")
	case "samsung_tizen_ws":
		return NewSamsung(addr)
	case "dlna_dmr":
		return NewDLNA(addr)
	case "kodi_jsonrpc":
		return NewKodi(addr)
	}
	return nil
}
func ForConfig(id, addr, credential string) TVDriver {
	switch id {
	case "sony_bravia_psk":
		return NewSony(addr, credential)
	case "lg_webos_ssap":
		d := NewLG(addr, true)
		d.ClientKey = credential
		return d
	case "hisense_vidaa_mqtt":
		return NewHisenseVIDAA(addr, credential)
	case "samsung_tizen_ws":
		d := NewSamsung(addr)
		d.Token = credential
		return d
	default:
		return ForID(id, addr)
	}
}

type Samsung struct {
	Base
	Token string
}

func NewSamsung(addr string) *Samsung {
	return &Samsung{Base: Base{id: "samsung_tizen_ws", addr: addr, client: httpClient(), sleeping: false}}
}
func (d *Samsung) dial() (*ws.Conn, error) {
	query := url.Values{"name": {base64.StdEncoding.EncodeToString([]byte("MenuBarHome"))}}
	if d.Token != "" {
		query.Set("token", d.Token)
	}
	addr := d.addr
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(strings.Trim(addr, "[]"), "8002")
	}
	endpoint := url.URL{Scheme: "wss", Host: addr, Path: "/api/v2/channels/samsung.remote.control", RawQuery: query.Encode()}
	c, err := ws.Dial(endpoint.String())
	if err != nil {
		return nil, errors.New("Samsung remote WebSocket connection failed")
	}
	return c, nil
}
func (d *Samsung) Probe() error {
	c, e := d.dial()
	if e != nil {
		return e
	}
	return c.Close()
}
func (d *Samsung) Snapshot() (Snapshot, error) {
	return Snapshot{ID: d.id, Name: "Samsung Tizen"}, d.Probe()
}
func (d *Samsung) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	c, e := d.dial()
	if e != nil {
		return e
	}
	defer c.Close()
	keys := map[string]string{"up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT", "select": "KEY_ENTER", "back": "KEY_RETURN", "home": "KEY_HOME", "menu": "KEY_MENU", "volumeUp": "KEY_VOLUP", "volumeDown": "KEY_VOLDOWN", "mute": "KEY_MUTE", "source": "KEY_SOURCE", "power": "KEY_POWER"}
	key := fmt.Sprint(a["key"])
	if v == "power.set" {
		key = "power"
	}
	mapped, ok := keys[key]
	if !ok {
		return errors.New("unsupported Samsung key")
	}
	b, _ := json.Marshal(map[string]any{"method": "ms.remote.control", "params": map[string]any{"Cmd": "Click", "DataOfCmd": mapped, "TypeOfRemote": "SendRemoteKey", "Option": "false"}})
	return c.WriteText(b)
}

var _ cipher.Block
