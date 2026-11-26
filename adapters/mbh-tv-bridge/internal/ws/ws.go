package ws

import (
	"bufio"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"strings"
	"time"
)

type Conn struct {
	net.Conn
	r *bufio.Reader
}

func Dial(raw string) (*Conn, error) {
	secure := strings.HasPrefix(raw, "wss://")
	u := strings.TrimPrefix(strings.TrimPrefix(raw, "ws://"), "wss://")
	host := u
	path := "/"
	if i := strings.IndexByte(u, '/'); i >= 0 {
		host = u[:i]
		path = u[i:]
	}
	var c net.Conn
	var e error
	if secure {
		c, e = tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", host, &tls.Config{InsecureSkipVerify: true, ServerName: strings.Split(host, ":")[0]})
	} else {
		c, e = net.DialTimeout("tcp", host, 5*time.Second)
	}
	if e != nil {
		return nil, e
	}
	key := fmt.Sprintf("%x", rand.Uint64())
	fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", path, host, key)
	br := bufio.NewReader(c)
	status, e := br.ReadString('\n')
	if e != nil || !strings.Contains(status, "101") {
		c.Close()
		return nil, errors.New("websocket upgrade failed")
	}
	accept := ""
	for {
		line, e := br.ReadString('\n')
		if e != nil {
			return nil, e
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if strings.HasPrefix(strings.ToLower(line), "sec-websocket-accept:") {
			accept = strings.TrimSpace(strings.SplitN(line, ":", 2)[1])
		}
	}
	h := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	_ = accept
	if accept != "" && accept != base64.StdEncoding.EncodeToString(h[:]) {
		c.Close()
		return nil, errors.New("websocket accept mismatch")
	}
	return &Conn{Conn: c, r: br}, nil
}
func (c *Conn) WriteText(p []byte) error {
	n := len(p)
	hdr := []byte{0x81}
	if n < 126 {
		hdr = append(hdr, byte(n)|0x80)
	} else if n <= 65535 {
		hdr = append(hdr, 126|0x80, byte(n>>8), byte(n))
	} else {
		return errors.New("frame too large")
	}
	mask := make([]byte, 4)
	binary.LittleEndian.PutUint32(mask, rand.Uint32())
	hdr = append(hdr, mask...)
	for i := range p {
		p[i] ^= mask[i%4]
	}
	_, e := c.Write(append(hdr, p...))
	return e
}
func (c *Conn) ReadText() ([]byte, error) {
	h := make([]byte, 2)
	if _, e := io.ReadFull(c.r, h); e != nil {
		return nil, e
	}
	n := int(h[1] & 127)
	if n == 126 {
		b := make([]byte, 2)
		io.ReadFull(c.r, b)
		n = int(binary.BigEndian.Uint16(b))
	} else if n == 127 {
		return nil, errors.New("large frame")
	}
	var mask []byte
	if h[1]&128 != 0 {
		mask = make([]byte, 4)
		io.ReadFull(c.r, mask)
	}
	b := make([]byte, n)
	if _, e := io.ReadFull(c.r, b); e != nil {
		return nil, e
	}
	for i := range b {
		if mask != nil {
			b[i] ^= mask[i%4]
		}
	}
	return b, nil
}
func (c *Conn) Close() error { return c.Conn.Close() }

var _ = http.MethodGet
