package driver

import (
	"bytes"
	"com.menubarhome.tv-bridge/internal/ws"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
func commandAllowed(verb string, args map[string]any) error {
	allowed := map[string]bool{"tv.power": true, "tv.wake": true, "tv.screenOff": true, "media.setVolume": true, "media.stepVolume": true, "media.setMute": true, "media.selectSource": true, "media.launchApp": true, "media.playPause": true, "media.play": true, "media.pause": true, "media.stop": true, "media.next": true, "media.previous": true, "media.seek": true, "remote.key": true}
	if !allowed[verb] {
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

type Xiaomi struct{ Base }

func NewXiaomi(addr string) *Xiaomi {
	return &Xiaomi{Base: Base{id: "xiaomi_6095", addr: ensureHTTPBase(addr), client: httpClient()}}
}
func (d *Xiaomi) Probe() error {
	var x any
	return getJSON(d.client, d.addr+"/request?action=isalive", &x)
}
func (d *Xiaomi) Snapshot() (Snapshot, error) {
	var x struct {
		Volume int `json:"volume"`
	}
	e := getJSON(d.client, d.addr+"/general?action=getvolume", &x)
	return Snapshot{ID: d.id, Name: "Xiaomi TV", Volume: x.Volume}, e
}
func (d *Xiaomi) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	if v == "media.selectSource" {
		s, _ := a["source"].(string)
		if !strings.HasPrefix(s, "hdmi") {
			return errors.New("invalid source")
		}
		r, e := d.client.Get(d.addr + "/controller?action=changesource&source=" + url.QueryEscape(s))
		if e != nil {
			return e
		}
		defer r.Body.Close()
		_, _ = io.Copy(io.Discard, r.Body)
		if r.StatusCode >= 300 {
			return fmt.Errorf("http status %s", r.Status)
		}
		return nil
	}
	k := fmt.Sprint(a["key"])
	codes := map[string]string{"up": "up", "down": "down", "left": "left", "right": "right", "select": "enter", "back": "back", "home": "home", "menu": "menu", "volumeUp": "volumeup", "volumeDown": "volumedown", "mute": "mute", "source": "source", "channelUp": "channelup", "channelDown": "channeldown", "playPause": "playpause", "info": "info"}
	code, ok := codes[k]
	if !ok {
		return errors.New("unsupported remote key")
	}
	r, e := d.client.Get(d.addr + "/controller?action=keyevent&keycode=" + url.QueryEscape(code))
	if e != nil {
		return e
	}
	defer r.Body.Close()
	if r.StatusCode >= 300 {
		return fmt.Errorf("http status %s", r.Status)
	}
	return nil
}

type Sony struct {
	Base
	PSK string
}

func NewSony(addr, psk string) *Sony {
	return &Sony{Base: Base{id: "sony_bravia", addr: ensureHTTPBase(addr), client: httpClient()}, PSK: psk}
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
	case "tv.power":
		method = "setPowerStatus"
		params = []any{map[string]any{"status": true}}
	case "tv.screenOff":
		method = "setPowerStatus"
		params = []any{map[string]any{"status": false}}
	case "media.setVolume":
		path = "/sony/audio"
		method = "setAudioVolume"
		params = []any{map[string]any{"volume": fmt.Sprint(a["volume"])}}
	case "media.setMute":
		path = "/sony/audio"
		method = "setAudioMute"
		params = []any{map[string]any{"status": a["muted"]}}
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
	methods := map[string]string{"media.playPause": "Player.PlayPause", "media.play": "Player.PlayPause", "media.pause": "Player.PlayPause", "media.stop": "Player.Stop", "media.next": "Player.GoNext", "media.previous": "Player.GoPrevious", "media.seek": "Player.Seek", "media.setVolume": "Application.SetVolume", "remote.key": "Input.ExecuteAction"}
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
		params["playerid"] = 1
		params["value"] = a["position"]
	}
	if v == "media.setVolume" {
		params["volume"] = a["volume"]
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
		seconds, _ := strconv.ParseFloat(fmt.Sprint(a["position"]), 64)
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
	return &TCL{Base: Base{id: "tcl_tnscreen", addr: addr, client: httpClient(), sleeping: false}, key: []byte("tnscreentnscreen"), iv: []byte{0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef}}
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
	if v == "tv.power" {
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
	return &AndroidADB{Base: Base{id: "android_adb", addr: addr, client: httpClient(), sleeping: false}}
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
	TLS       bool
	ClientKey string
}

func NewLG(addr string, tlsOn bool) *LG {
	return &LG{Base: Base{id: "lg_webos", addr: addr, client: httpClient(), sleeping: false}, TLS: tlsOn}
}
func (d *LG) Probe() error {
	if !d.TLS {
		return errors.New("LG websocket disabled")
	}
	c, e := ws.Dial("wss://" + d.addr + "/")
	if e != nil {
		return e
	}
	return c.Close()
}
func (d *LG) Snapshot() (Snapshot, error) {
	if e := d.Probe(); e != nil {
		return Snapshot{}, e
	}
	return Snapshot{ID: d.id, Name: "LG webOS"}, nil
}
func (d *LG) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	if !d.TLS {
		return errors.New("LG websocket disabled")
	}
	c, e := ws.Dial("wss://" + d.addr + "/")
	if e != nil {
		return e
	}
	defer c.Close()
	uri := map[string]string{"tv.power": "ssap://system/turnOff", "tv.screenOff": "ssap://com.webos.service.tv.display/turnOffScreen", "media.setVolume": "ssap://audio/setVolume", "media.setMute": "ssap://audio/setMute"}[v]
	if uri == "" {
		return errors.New("unsupported LG action")
	}
	b, _ := json.Marshal(map[string]any{"id": "1", "type": "request", "uri": uri, "payload": a})
	return c.WriteText(b)
}

func ForID(id, addr string) TVDriver {
	switch id {
	case "xiaomi_6095":
		return NewXiaomi(addr)
	case "tcl_tnscreen":
		return NewTCL(addr)
	case "android_adb":
		return NewAndroidADB(addr)
	case "lg_webos":
		return NewLG(addr, true)
	case "sony_bravia":
		return NewSony(addr, "")
	case "samsung_tizen":
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
	case "sony_bravia":
		return NewSony(addr, credential)
	case "lg_webos":
		d := NewLG(addr, true)
		d.ClientKey = credential
		return d
	case "samsung_tizen":
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
	return &Samsung{Base: Base{id: "samsung_tizen", addr: addr, client: httpClient(), sleeping: false}}
}
func (d *Samsung) Probe() error {
	c, e := ws.Dial("wss://" + d.addr + "/")
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
	c, e := ws.Dial("wss://" + d.addr + "/")
	if e != nil {
		return e
	}
	defer c.Close()
	keys := map[string]string{"up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT", "select": "KEY_ENTER", "back": "KEY_RETURN", "home": "KEY_HOME", "menu": "KEY_MENU", "volumeUp": "KEY_VOLUP", "volumeDown": "KEY_VOLDOWN", "mute": "KEY_MUTE", "source": "KEY_SOURCE", "power": "KEY_POWER"}
	key := fmt.Sprint(a["key"])
	if v == "tv.power" {
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
