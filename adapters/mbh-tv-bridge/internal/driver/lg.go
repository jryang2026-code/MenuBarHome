package driver

import (
	"com.menubarhome.tv-bridge/internal/ws"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"
)

var lgManifest = map[string]any{
	"manifestVersion": 1, "appVersion": "1.1",
	"signed": map[string]any{
		"created": "20140509", "appId": "com.lge.test", "vendorId": "com.lge",
		"localizedAppNames": map[string]string{"": "LG Remote App"}, "localizedVendorNames": map[string]string{"": "LG Electronics"},
		"permissions": []string{"TEST_SECURE", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_NOTIFICATIONS", "SEARCH", "WRITE_SETTINGS", "WRITE_NOTIFICATION_ALERT", "CONTROL_POWER", "READ_CURRENT_CHANNEL", "READ_RUNNING_APPS", "READ_UPDATE_INFO", "UPDATE_FROM_REMOTE_APP", "READ_LGE_TV_INPUT_EVENTS", "READ_TV_CURRENT_TIME"},
		"serial":      "2f930e2d2cfe083771f68e4fe7bb07",
	},
	"permissions": []string{"LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV", "CONTROL_POWER", "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO", "READ_SETTINGS", "CONTROL_TV_SCREEN", "CONTROL_TV_POWER", "CONTROL_WOL"},
}

type ssapMsg struct{ Type, ID, Error string; Payload map[string]any }

func (d *LG) SetMAC(mac string) { d.mu.Lock(); d.MAC = strings.TrimSpace(mac); d.mu.Unlock() }
func (d *LG) getKey() string    { d.mu.Lock(); defer d.mu.Unlock(); return strings.TrimSpace(d.ClientKey) }
func (d *LG) getMAC() string    { d.mu.Lock(); defer d.mu.Unlock(); return strings.TrimSpace(d.MAC) }
func (d *LG) ioTimeout() time.Duration { if d.Timeout > 0 { return d.Timeout }; return 5 * time.Second }
func lgExtractHost(raw string) string {
	if u, err := url.Parse(raw); err == nil && u.Hostname() != "" { return u.Hostname() }
	if h, _, err := net.SplitHostPort(raw); err == nil { return h }
	return raw
}
func (d *LG) dialAndRegister(waitPrompt bool, timeout time.Duration) (*ws.Conn, string, error) {
	raw := strings.TrimSpace(d.addr)
	if !strings.HasPrefix(raw, "ws://") && !strings.HasPrefix(raw, "wss://") {
		if !d.TLS { return nil, "", errors.New("LG websocket disabled") }
		raw = strings.TrimRight(raw, "/"); if _, _, err := net.SplitHostPort(raw); err != nil { raw = net.JoinHostPort(raw, "3001") }
		raw = "wss://" + raw + "/"
	} else if strings.Count(raw, "/") < 3 { raw += "/" }
	key := d.getKey(); c, err := ws.Dial(raw); if err != nil { return nil, "", sanitizeErr(err, key) }
	_ = c.SetDeadline(time.Now().Add(timeout))
	pl := map[string]any{"forcePairing": false, "pairingType": "PROMPT", "manifest": lgManifest}; if key != "" { pl["client-key"] = key }
	reg, _ := json.Marshal(map[string]any{"type": "register", "id": "register_0", "payload": pl})
	if err := c.WriteText(reg); err != nil { _ = c.Close(); return nil, "", sanitizeErr(err, key) }
	for {
		b, err := c.ReadText(); if err != nil { _ = c.Close(); return nil, "", sanitizeErr(err, key) }
		var m ssapMsg; if json.Unmarshal(b, &m) != nil { continue }
		if m.Type == "registered" {
			nk, _ := m.Payload["client-key"].(string); if nk = strings.TrimSpace(nk); nk != "" { d.mu.Lock(); d.ClientKey = nk; d.mu.Unlock() }
			return c, nk, nil
		}
		if m.Type == "response" { if pt, _ := m.Payload["pairingType"].(string); pt == "PROMPT" && !waitPrompt { _ = c.Close(); return nil, "", errors.New("LG pairing required") } }
		if m.Type == "error" { _ = c.Close(); em := strings.TrimSpace(m.Error); if em == "" { em = "LG registration rejected" }; return nil, "", sanitizeErr(errors.New(em), key) }
	}
}
func (d *LG) ssapCall(c *ws.Conn, id, uri string, payload map[string]any) (map[string]any, error) {
	req := map[string]any{"id": id, "type": "request", "uri": uri}; if payload != nil { req["payload"] = payload }
	b, _ := json.Marshal(req); key := d.getKey(); if err := c.WriteText(b); err != nil { return nil, sanitizeErr(err, key) }
	for {
		raw, err := c.ReadText(); if err != nil { return nil, sanitizeErr(err, key) }
		var m ssapMsg; if json.Unmarshal(raw, &m) != nil || m.ID != id { continue }
		if m.Type == "error" { em := strings.TrimSpace(m.Error); if em == "" { em = "LG SSAP request failed" }; return nil, sanitizeErr(errors.New(em), key) }
		if m.Type == "response" {
			if rv, ok := m.Payload["returnValue"].(bool); ok && !rv { em, _ := m.Payload["errorText"].(string); if em == "" { em = "LG SSAP command rejected" }; return nil, sanitizeErr(errors.New(em), key) }
			return m.Payload, nil
		}
	}
}
func (d *LG) Pair() (string, error) {
	to := 15 * time.Second; if d.PairTimeout > 0 { to = d.PairTimeout }
	c, key, err := d.dialAndRegister(true, to); if err != nil { return "", err }
	_ = c.Close(); if key == "" { return "", errors.New("LG pairing returned empty client key") }; return key, nil
}
func (d *LG) Probe() error { c, _, err := d.dialAndRegister(false, d.ioTimeout()); if err != nil { return err }; return c.Close() }
func (d *LG) Snapshot() (Snapshot, error) {
	c, _, err := d.dialAndRegister(false, d.ioTimeout()); if err != nil { return Snapshot{}, err }
	defer c.Close(); snap := Snapshot{ID: d.id, Name: "LG webOS", Power: "on"}
	if p, err := d.ssapCall(c, "snap_vol", "ssap://audio/getVolume", nil); err == nil {
		muted, _ := p["muted"].(bool)
		if vs, ok := p["volumeStatus"].(map[string]any); ok {
			if m, ok := vs["muteStatus"].(bool); ok { muted = m }
			if v, ok := vs["volume"].(float64); ok { snap.Volume, snap.Muted = clampInt(int(v+0.5), 0, 100), muted }
		} else if v, ok := p["volume"].(float64); ok { snap.Volume, snap.Muted = clampInt(int(v+0.5), 0, 100), muted }
	}
	if p, err := d.ssapCall(c, "snap_app", "ssap://com.webos.applicationManager/getForegroundAppInfo", nil); err == nil {
		if id, _ := p["appId"].(string); id != "" {
			l := strings.ToLower(strings.TrimSpace(id)); snap.Source = strings.TrimSpace(id)
			for _, n := range []string{"1", "2", "3", "4"} { if strings.HasSuffix(l, ".hdmi"+n) || l == "hdmi_"+n || l == "hdmi"+n { snap.Source = "HDMI " + n } }
			for k, v := range map[string]string{"youtube": "YouTube", "netflix": "Netflix", "bilibili": "Bilibili", "apple": "Apple TV", "livetv": "Live TV"} { if strings.Contains(l, k) { snap.Source = v } }
		}
	}
	return snap, nil
}
func (d *LG) sendWOL() error {
	cl := strings.NewReplacer(":", "", "-", "", " ", "").Replace(d.getMAC()); mb, err := hex.DecodeString(cl)
	if err != nil || len(cl) != 12 || len(mb) != 6 { return errors.New("invalid MAC address for Wake-on-LAN") }
	pkt := append(make([]byte, 0, 102), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff); for range 16 { pkt = append(pkt, mb...) }
	targets := []string{d.wolTarget}
	if d.wolTarget == "" {
		host := lgExtractHost(d.addr); targets = []string{"255.255.255.255:9"}
		if ip := net.ParseIP(host).To4(); ip != nil { targets = append(targets, fmt.Sprintf("%d.%d.%d.255:9", ip[0], ip[1], ip[2]), net.JoinHostPort(host, "9")) }
	}
	var lastErr error; sent := 0
	for _, t := range targets {
		conn, err := net.DialTimeout("udp4", t, time.Second); if err != nil { lastErr = err; continue }
		_, wErr := conn.Write(pkt); _ = conn.Close(); if wErr != nil { lastErr = wErr } else { sent++ }
	}
	if sent == 0 && lastErr != nil { return lastErr }; return nil
}
func (d *LG) Execute(v string, a map[string]any) error {
	if err := commandAllowed(v, a); err != nil { return err }
	if v == "power.wake" { return d.sendWOL() }
	if v == "power.set" {
		isOn, err := parseBoolArg(a, "isOn"); if err != nil { return err }
		if isOn {
			if d.getMAC() != "" { return d.sendWOL() }
			c, _, err := d.dialAndRegister(false, d.ioTimeout()); if err != nil { return errors.New("LG wake requires configured MAC address") }
			defer c.Close(); _, err = d.ssapCall(c, "pwr_on", "ssap://com.webos.service.tvpower/power/turnOnScreen", map[string]any{"standbyMode": "active"}); return err
		}
	}
	c, _, err := d.dialAndRegister(false, d.ioTimeout()); if err != nil { return err }
	defer c.Close()
	switch v {
	case "power.set": _, err = d.ssapCall(c, "pwr_off", "ssap://system/turnOff", nil)
	case "power.screenOff": _, err = d.ssapCall(c, "scr_off", "ssap://com.webos.service.tvpower/power/turnOffScreen", map[string]any{"standbyMode": "active"})
	case "volume.set": vol, e := parseVolumeLevel(a); if e != nil { return e }; _, err = d.ssapCall(c, "vol_1", "ssap://audio/setVolume", map[string]any{"volume": vol})
	case "mute.set": muted, e := parseBoolArg(a, "isMuted", "muted"); if e != nil { return e }; _, err = d.ssapCall(c, "mute_1", "ssap://audio/setMute", map[string]any{"mute": muted})
	case "input.select":
		s, ok := a["source"].(string); if s = strings.TrimSpace(s); !ok || s == "" { return errors.New("invalid source") }
		if comp := strings.ToUpper(strings.NewReplacer(" ", "", "_", "").Replace(s)); len(comp) == 5 && strings.HasPrefix(comp, "HDMI") && comp[4] >= '1' && comp[4] <= '4' { s = "HDMI_" + comp[4:] }
		_, err = d.ssapCall(c, "in_1", "ssap://tv/switchInput", map[string]any{"inputId": s})
	case "media.play", "media.pause", "media.stop", "media.playPause":
		d.mu.Lock(); next := v == "media.play" || (v == "media.playPause" && !d.mediaPlaying); d.mediaPlaying = next; d.mu.Unlock()
		uri := map[string]string{"media.play": "ssap://media.controls/play", "media.pause": "ssap://media.controls/pause", "media.stop": "ssap://media.controls/stop"}[v]
		if v == "media.playPause" { uri = "ssap://media.controls/pause"; if next { uri = "ssap://media.controls/play" } }
		_, err = d.ssapCall(c, "media_1", uri, nil)
	case "remote.key":
		k, _ := a["key"].(string)
		if uri, ok := map[string]string{"volumeUp": "ssap://audio/volumeUp", "volumeDown": "ssap://audio/volumeDown", "channelUp": "ssap://tv/channelUp", "channelDown": "ssap://tv/channelDown"}[k]; ok { _, err = d.ssapCall(c, "rk_1", uri, nil); return err }
		btn, ok := map[string]string{"up": "UP", "down": "DOWN", "left": "LEFT", "right": "RIGHT", "select": "ENTER", "back": "BACK", "home": "HOME", "menu": "MENU", "mute": "MUTE", "source": "EXTERNAL_INPUT", "playPause": "PLAY", "info": "INFO"}[k]
		if !ok { return errors.New("unsupported remote key") }
		p, err := d.ssapCall(c, "ptr_1", "ssap://com.webos.service.networkinput/getPointerInputSocket", nil); if err != nil { return err }
		sp, _ := p["socketPath"].(string); u, err := url.Parse(sp)
		if err != nil || (u.Scheme != "ws" && u.Scheme != "wss") || !strings.EqualFold(u.Hostname(), lgExtractHost(d.addr)) { return errors.New("invalid LG pointer socket path") }
		pc, err := ws.Dial(sp); if err != nil { return sanitizeErr(err, d.getKey()) }
		defer pc.Close(); _ = pc.SetDeadline(time.Now().Add(d.ioTimeout())); return pc.WriteText([]byte("type:button\nname:" + btn + "\n\n"))
	default: return errors.New("unsupported LG action")
	}
	return err
}
