package ws

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand"
	"net"
	"net/url"
	"strings"
	"time"
)

const MaxFrame = 1 << 20

type Conn struct {
	net.Conn
	r *bufio.Reader
}

func Dial(raw string) (*Conn, error) { return DialWithCertificateCheck(raw, nil) }
func DialWithCertificateCheck(raw string, check func(string) error) (*Conn, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || (u.Scheme != "ws" && u.Scheme != "wss") {
		return nil, errors.New("invalid WebSocket endpoint")
	}
	host := u.Host
	if u.Port() == "" {
		port := "80"
		if u.Scheme == "wss" {
			port = "443"
		}
		host = net.JoinHostPort(u.Hostname(), port)
	}
	d := net.Dialer{Timeout: 5 * time.Second}
	var c net.Conn
	var e error
	if u.Scheme == "wss" {
		tlsConn, err := tls.DialWithDialer(&d, "tcp", host, &tls.Config{InsecureSkipVerify: true, ServerName: u.Hostname()})
		if err != nil {
			return nil, err
		}
		if check != nil {
			chain := tlsConn.ConnectionState().PeerCertificates
			if len(chain) == 0 {
				_ = tlsConn.Close()
				return nil, errors.New("missing WebSocket peer certificate")
			}
			sum := sha256.Sum256(chain[0].Raw)
			if err := check(fmt.Sprintf("%x", sum)); err != nil {
				_ = tlsConn.Close()
				return nil, err
			}
		}
		c = tlsConn
	} else {
		if check != nil {
			return nil, errors.New("TLS required for WebSocket certificate check")
		}
		c, e = d.Dial("tcp", host)
	}
	if e != nil {
		return nil, e
	}
	closeOnErr := func(err error) (*Conn, error) { c.Close(); return nil, err }
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	rawKey := make([]byte, 16)
	if _, e := rand.Read(rawKey); e != nil {
		return closeOnErr(e)
	}
	key := base64.StdEncoding.EncodeToString(rawKey)
	if _, err := fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", u.RequestURI(), u.Host, key); err != nil {
		return closeOnErr(err)
	}
	br := bufio.NewReader(c)
	status, e := br.ReadString('\n')
	if e != nil {
		return closeOnErr(e)
	}
	if !strings.HasPrefix(strings.TrimSpace(status), "HTTP/1.1 101") {
		return closeOnErr(errors.New("websocket upgrade failed"))
	}
	upgrade, connection, accept := "", "", ""
	for {
		line, e := br.ReadString('\n')
		if e != nil {
			return closeOnErr(e)
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		switch strings.ToLower(parts[0]) {
		case "upgrade":
			upgrade = strings.TrimSpace(parts[1])
		case "connection":
			connection = strings.TrimSpace(parts[1])
		case "sec-websocket-accept":
			accept = strings.TrimSpace(parts[1])
		}
	}
	if !strings.EqualFold(upgrade, "websocket") || !strings.Contains(strings.ToLower(connection), "upgrade") || accept == "" {
		return closeOnErr(errors.New("invalid websocket handshake headers"))
	}
	h := sha1Bytes([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	if accept != base64.StdEncoding.EncodeToString(h) {
		return closeOnErr(errors.New("websocket accept mismatch"))
	}
	_ = c.SetDeadline(time.Time{})
	return &Conn{Conn: c, r: br}, nil
}
func sha1Bytes(b []byte) []byte { h := sha1.New(); h.Write(b); return h.Sum(nil) }
func (c *Conn) WriteText(in []byte) error {
	p := append([]byte(nil), in...)
	n := len(p)
	if n > MaxFrame {
		return errors.New("frame too large")
	}
	hdr := []byte{0x81}
	if n < 126 {
		hdr = append(hdr, byte(n)|0x80)
	} else {
		hdr = append(hdr, 126|0x80, byte(n>>8), byte(n))
	}
	mask := make([]byte, 4)
	binary.LittleEndian.PutUint32(mask, mathrand.Uint32())
	hdr = append(hdr, mask...)
	for i := range p {
		p[i] ^= mask[i%4]
	}
	_, e := c.Write(append(hdr, p...))
	return e
}
func (c *Conn) ReadText() ([]byte, error) {
	for {
		h := make([]byte, 2)
		if _, e := io.ReadFull(c.r, h); e != nil {
			return nil, e
		}
		n := int(h[1] & 127)
		if n == 126 {
			b := make([]byte, 2)
			if _, e := io.ReadFull(c.r, b); e != nil {
				return nil, e
			}
			n = int(binary.BigEndian.Uint16(b))
		} else if n == 127 {
			return nil, errors.New("large frame")
		}
		if n > MaxFrame {
			return nil, errors.New("frame too large")
		}
		mask := make([]byte, 0, 4)
		if h[1]&128 != 0 {
			mask = make([]byte, 4)
			if _, e := io.ReadFull(c.r, mask); e != nil {
				return nil, e
			}
		}
		b := make([]byte, n)
		if _, e := io.ReadFull(c.r, b); e != nil {
			return nil, e
		}
		for i := range b {
			if len(mask) > 0 {
				b[i] ^= mask[i%4]
			}
		}
		switch h[0] & 0x0f {
		case 0x1:
			return b, nil
		case 0x8:
			return nil, io.EOF
		case 0x9:
			_ = c.writeControl(0xA, b)
		case 0xA:
			continue
		default:
			continue
		}
	}
}
func (c *Conn) writeControl(op byte, p []byte) error {
	if len(p) > 125 {
		return errors.New("control frame too large")
	}
	return func() error { _, e := c.Write(append([]byte{0x80 | op, byte(len(p))}, p...)); return e }()
}
func (c *Conn) Close() error { return c.Conn.Close() }
