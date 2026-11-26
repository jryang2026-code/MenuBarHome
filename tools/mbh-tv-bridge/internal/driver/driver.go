package driver

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
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
	Title, Artist, Album, ArtworkURI string  `json:"title,omitempty"`
	Duration, Position               float64 `json:"duration,omitempty"`
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
	return &Xiaomi{Base: Base{id: "xiaomi_6095", addr: strings.TrimRight(addr, "/"), client: httpClient()}}
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
		_, e := d.client.Get(d.addr + "/controller?action=changesource&source=" + url.QueryEscape(s))
		return e
	}
	k := fmt.Sprint(a["key"])
	_, e := d.client.Get(d.addr + "/controller?action=keyevent&keycode=" + url.QueryEscape(k))
	return e
}

type Sony struct {
	Base
	PSK string
}

func NewSony(addr, psk string) *Sony {
	return &Sony{Base: Base{id: "sony_bravia", addr: strings.TrimRight(addr, "/"), client: httpClient()}, PSK: psk}
}
func (d *Sony) Probe() error { _, e := d.client.Get(d.addr + "/sony/system"); return e }
func (d *Sony) Snapshot() (Snapshot, error) {
	var x any
	e := postJSON(d.client, d.addr+"/sony/system", map[string]any{"method": "getPowerStatus", "params": []any{}, "id": 1, "version": "1.0"}, &x)
	return Snapshot{ID: d.id, Name: "Sony Bravia"}, e
}
func (d *Sony) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	return nil
}

type Kodi struct{ Base }

func NewKodi(addr string) *Kodi {
	return &Kodi{Base: Base{id: "kodi_jsonrpc", addr: strings.TrimRight(addr, "/"), client: httpClient()}}
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
	return nil
}

type DLNA struct{ Base }

func NewDLNA(addr string) *DLNA {
	return &DLNA{Base: Base{id: "dlna_dmr", addr: strings.TrimRight(addr, "/"), client: httpClient()}}
}
func (d *DLNA) Probe() error                { return nil }
func (d *DLNA) Snapshot() (Snapshot, error) { return Snapshot{ID: d.id, Name: "DLNA Renderer"}, nil }
func (d *DLNA) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	return nil
}

type TCL struct {
	Base
	conn    net.Conn
	key, iv []byte
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
func (d *TCL) Probe() error                { return nil }
func (d *TCL) Snapshot() (Snapshot, error) { return Snapshot{ID: d.id, Name: "TCL/FFALCON"}, nil }
func (d *TCL) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	return nil
}

type AndroidADB struct {
	Base
	mu   sync.Mutex
	conn net.Conn
}

func NewAndroidADB(addr string) *AndroidADB {
	return &AndroidADB{Base: Base{id: "android_adb", addr: addr, client: httpClient(), sleeping: false}}
}
func (d *AndroidADB) Probe() error {
	c, e := net.DialTimeout("tcp", d.addr, 2*time.Second)
	if e == nil {
		d.mu.Lock()
		d.conn = c
		d.mu.Unlock()
	}
	return e
}
func (d *AndroidADB) Snapshot() (Snapshot, error) { return Snapshot{ID: d.id, Name: "Android TV"}, nil }
func (d *AndroidADB) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	k := fmt.Sprint(a["key"])
	allowed := map[string]bool{"up": true, "down": true, "left": true, "right": true, "select": true, "back": true, "home": true, "volumeUp": true, "volumeDown": true, "mute": true, "power": true}
	if v == "remote.key" && !allowed[k] {
		return errors.New("unsafe adb key")
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
	if d.TLS {
		_, e := tls.Dial("tcp", d.addr, &tls.Config{InsecureSkipVerify: true})
		return e
	}
	return nil
}
func (d *LG) Snapshot() (Snapshot, error) { return Snapshot{ID: d.id, Name: "LG webOS"}, nil }
func (d *LG) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	return nil
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

type Samsung struct {
	Base
	Token string
}

func NewSamsung(addr string) *Samsung {
	return &Samsung{Base: Base{id: "samsung_tizen", addr: addr, client: httpClient(), sleeping: false}}
}
func (d *Samsung) Probe() error                { return nil }
func (d *Samsung) Snapshot() (Snapshot, error) { return Snapshot{ID: d.id, Name: "Samsung Tizen"}, nil }
func (d *Samsung) Execute(v string, a map[string]any) error {
	if e := commandAllowed(v, a); e != nil {
		return e
	}
	return nil
}

var _ cipher.Block
