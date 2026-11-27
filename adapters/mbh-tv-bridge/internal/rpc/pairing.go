package rpc

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"com.menubarhome.tv-bridge/internal/driver"
)

const (
	pairingTTL    = 2 * time.Minute
	tvUserConsent = "tvUserConsent"
)

type pairingSession struct {
	nativeID string
	method   string
	expires  time.Time
	device   *driver.LG
}

func (s *Server) handlePairing(r Request) Response {
	if r.Method == "pairing.begin" {
		var p struct {
			NativeID string `json:"nativeId"`
			Method   string `json:"method"`
		}
		if json.Unmarshal(r.Params, &p) != nil || strings.TrimSpace(p.NativeID) == "" || strings.TrimSpace(p.Method) == "" {
			return errResp(r.ID, -32602, "invalid pairing parameters")
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.readOnly {
			return errResp(r.ID, -32004, "read-only protocol")
		}
		device, ok := s.devices[p.NativeID]
		if !ok {
			return errResp(r.ID, -32005, "device unavailable")
		}
		lg, ok := device.(*driver.LG)
		if !ok || p.Method != tvUserConsent {
			return errResp(r.ID, -32004, "unsupported pairing method")
		}
		var randomID [16]byte
		rand.Read(randomID[:])
		id := "pair-" + hex.EncodeToString(randomID[:])
		now := time.Now()
		for id, session := range s.pairings {
			if !now.Before(session.expires) || session.nativeID == p.NativeID {
				delete(s.pairings, id)
			}
		}
		s.pairings[id] = pairingSession{nativeID: p.NativeID, method: p.Method, expires: now.Add(pairingTTL), device: lg}
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{
			"pairingId": id, "instructions": []string{"在电视上确认 MenuBarHome 连接请求。"},
		}}
	}

	var p struct {
		PairingID string `json:"pairingId"`
		Inputs    struct {
			UserConfirmation string `json:"userConfirmation"`
		} `json:"inputs"`
		Reason string `json:"reason"`
	}
	if json.Unmarshal(r.Params, &p) != nil || strings.TrimSpace(p.PairingID) == "" {
		return errResp(r.ID, -32602, "invalid pairing parameters")
	}
	confirmed := p.Inputs.UserConfirmation == "approved-on-device"
	p.Inputs.UserConfirmation = ""
	s.mu.Lock()
	if s.readOnly {
		s.mu.Unlock()
		return errResp(r.ID, -32004, "read-only protocol")
	}
	session, ok := s.pairings[p.PairingID]
	if !ok || !time.Now().Before(session.expires) {
		delete(s.pairings, p.PairingID)
		s.mu.Unlock()
		return errResp(r.ID, -32602, "unknown or expired pairingId")
	}
	if r.Method == "pairing.submit" && (session.method != tvUserConsent || !confirmed) {
		s.mu.Unlock()
		return errResp(r.ID, -32602, "TV pairing confirmation required")
	}
	delete(s.pairings, p.PairingID)
	s.mu.Unlock()
	if r.Method == "pairing.cancel" {
		return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"cancelled": true}}
	}
	if _, err := session.device.Pair(); err != nil {
		return errResp(r.ID, -32002, "TV pairing failed")
	}
	return Response{JSONRPC: "2.0", ID: r.ID, Result: map[string]any{"paired": true, "nativeId": session.nativeID}}
}
