#!/usr/bin/env python3
"""Guest-only loopback DNS over HTTPS; no access to the host's DNS service."""
import socketserver
import struct
import sys
import time
import urllib.request

DO_H_UPSTREAMS = (
    "https://223.5.5.5/dns-query",
    "https://1.12.12.12/dns-query",
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
)

# macOS stub resolver abandons one lookup after roughly 5 s, so a reply that arrives later is
# useless. Every upstream tried for a single query shares this budget instead of each getting a
# fresh timeout, which kept the worst case around 14 s.
QUERY_DEADLINE = 4.5


def _default_opener():
    # Never use an environment proxy or a hostname requiring DNS bootstrap.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _set_read_timeout(response, seconds: float) -> None:
    """Best-effort per-read socket timeout; `open()`'s timeout is fixed when it was set."""
    try:
        response.fp.raw._sock.settimeout(max(0.01, seconds))
    except (AttributeError, OSError):
        pass


def _read_answer(response, expires_at: float, monotonic, timeout: float) -> bytes:
    """Read the DoH body in chunks so a slow upstream cannot outlive the query deadline.

    The opener's timeout bounds one blocking socket operation, not the whole response, so a
    trickling upstream could otherwise hand us an answer the resolver already gave up on.
    """
    read_chunk = getattr(response, "read1", None)
    body = bytearray()
    while len(body) < 65535:
        remaining = expires_at - monotonic()
        if remaining <= 0:
            raise TimeoutError("DNS query budget spent while reading the answer")
        _set_read_timeout(response, min(timeout, remaining))
        limit = 65535 - len(body)
        chunk = read_chunk(limit) if read_chunk is not None else response.read(limit)
        if not chunk:
            break
        body += chunk
        if read_chunk is None:
            break
    if monotonic() > expires_at:
        raise TimeoutError("DNS answer arrived after the query budget")
    return bytes(body)


def resolve_dns_packet(
    packet: bytes,
    upstreams=DO_H_UPSTREAMS,
    timeout: float = 3.5,
    opener_factory=_default_opener,
    deadline: float = QUERY_DEADLINE,
    monotonic=time.monotonic,
) -> bytes | None:
    if len(packet) < 12:
        return None
    opener = opener_factory()
    expires_at = monotonic() + deadline
    for upstream in upstreams:
        remaining = expires_at - monotonic()
        if remaining <= 0:
            print("DNS query budget spent; no upstream left", flush=True)
            break
        request = urllib.request.Request(
            upstream,
            data=packet,
            headers={
                "Content-Type": "application/dns-message",
                "Accept": "application/dns-message",
            },
            method="POST",
        )
        try:
            # Only the time left for the whole query, never a second full timeout.
            with opener.open(request, timeout=min(timeout, remaining)) as response:
                answer = _read_answer(response, expires_at, monotonic, timeout)
        except Exception as error:
            print(f"DNS upstream {upstream} failed: {error}", flush=True)
            continue
        if len(answer) >= 12 and (struct.unpack("!H", answer[2:4])[0] & 0x000F) != 2:
            return answer
    # Echo the question with QR, RD, RA and SERVFAIL set.
    return packet[:2] + struct.pack("!H", 0x8182) + packet[4:]


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, connection = self.request
        answer = resolve_dns_packet(packet)
        if answer is not None:
            connection.sendto(answer, self.client_address)


def _run_self_test() -> int:
    assert resolve_dns_packet(b"\x12\x34\x01\x00") is None

    query = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
    servfail_reply = query[:2] + struct.pack("!H", 0x8182) + query[4:]
    noerror_reply = query[:2] + struct.pack("!H", 0x8180) + query[4:]

    class _FakeResponse:
        def __init__(self, payload: bytes):
            self._payload = payload

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self, _limit: int = -1) -> bytes:
            return self._payload

    class _FallbackOpener:
        def __init__(self):
            self.calls: list[str] = []

        def open(self, request, timeout=None):
            url = request.full_url
            self.calls.append(url)
            if url == DO_H_UPSTREAMS[0]:
                raise TimeoutError("upstream timed out")
            if url == DO_H_UPSTREAMS[1]:
                return _FakeResponse(servfail_reply)
            return _FakeResponse(noerror_reply)

    fallback_opener = _FallbackOpener()
    resolved = resolve_dns_packet(query, opener_factory=lambda: fallback_opener)
    assert resolved == noerror_reply
    assert fallback_opener.calls == list(DO_H_UPSTREAMS[:3])

    class _AllFailingOpener:
        def open(self, request, timeout=None):
            if request.full_url == DO_H_UPSTREAMS[0]:
                raise OSError("network unreachable")
            return _FakeResponse(servfail_reply)

    failed = resolve_dns_packet(query, opener_factory=_AllFailingOpener)
    assert failed == servfail_reply
    assert struct.unpack("!H", failed[2:4])[0] == 0x8182

    # Four stalled upstreams must share one budget: 3.5 s, then only the 1 s that is left.
    class _FakeClock:
        def __init__(self):
            self.elapsed = 0.0

        def __call__(self):
            return self.elapsed

    class _StallingOpener:
        def __init__(self, clock):
            self.clock = clock
            self.timeouts: list[float] = []

        def open(self, request, timeout=None):
            self.timeouts.append(timeout)
            self.clock.elapsed += timeout
            raise TimeoutError("upstream stalled")

    fake_clock = _FakeClock()
    stalled = _StallingOpener(fake_clock)
    stalled_reply = resolve_dns_packet(
        query, opener_factory=lambda: stalled, monotonic=fake_clock
    )
    assert stalled_reply == servfail_reply
    assert stalled.timeouts == [3.5, 1.0], stalled.timeouts
    assert fake_clock.elapsed <= QUERY_DEADLINE + 1e-6, fake_clock.elapsed

    # A response that trickles in must be cut off too: `open()`'s timeout only bounds one socket
    # operation, so the read loop checks the shared budget between chunks.
    class _TricklingResponse:
        def __init__(self, clock, state):
            self.clock = clock
            self.state = state

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read1(self, _limit: int = -1) -> bytes:
            self.clock.elapsed += 0.1
            start = self.state["delivered"]
            end = min(len(query), start + 4)
            self.state["delivered"] = end
            return query[start:end]

        def read(self, _limit: int = -1) -> bytes:
            # What a single `read()` would hand back: the whole answer, however late it is.
            self.clock.elapsed += 0.5
            start = self.state["delivered"]
            self.state["delivered"] = len(query)
            return query[start:]

    class _TricklingOpener:
        def __init__(self, clock):
            self.clock = clock
            self.state = {"delivered": 0}

        def open(self, request, timeout=None):
            return _TricklingResponse(self.clock, self.state)

    trickle_clock = _FakeClock()
    trickling = _TricklingOpener(trickle_clock)
    trickle_reply = resolve_dns_packet(
        query, opener_factory=lambda: trickling, deadline=0.35, monotonic=trickle_clock
    )
    assert trickle_reply == servfail_reply
    assert trickling.state["delivered"] < len(query), trickling.state
    assert trickle_clock.elapsed <= 0.35 + 0.1 + 1e-6, trickle_clock.elapsed

    # Same guard on the real clock: a stalling upstream burns its slice and the query answers
    # instead of retrying three more times.
    class _WallClockStall:
        def __init__(self):
            self.calls = 0

        def open(self, request, timeout=None):
            self.calls += 1
            time.sleep(timeout or 0)
            raise TimeoutError("upstream stalled")

    wall_stall = _WallClockStall()
    started = time.monotonic()
    wall_reply = resolve_dns_packet(query, opener_factory=lambda: wall_stall, deadline=0.2)
    wall_elapsed = time.monotonic() - started
    assert wall_reply == servfail_reply
    assert wall_stall.calls <= 2, wall_stall.calls
    assert wall_elapsed < 1.0, wall_elapsed
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        raise SystemExit(_run_self_test())
    with socketserver.ThreadingUDPServer(("127.0.0.1", 53), DNSHandler) as server:
        server.daemon_threads = True
        server.serve_forever()
