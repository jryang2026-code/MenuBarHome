#!/usr/bin/env python3
"""Guest-only loopback DNS over HTTPS; no access to the host's DNS service."""
import socketserver
import struct
import sys
import urllib.request

DO_H_UPSTREAMS = (
    "https://223.5.5.5/dns-query",
    "https://1.12.12.12/dns-query",
    "https://1.1.1.1/dns-query",
    "https://1.0.0.1/dns-query",
)


def _default_opener():
    # Never use an environment proxy or a hostname requiring DNS bootstrap.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def resolve_dns_packet(
    packet: bytes,
    upstreams=DO_H_UPSTREAMS,
    timeout: float = 3.5,
    opener_factory=_default_opener,
) -> bytes | None:
    if len(packet) < 12:
        return None
    opener = opener_factory()
    for upstream in upstreams:
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
            with opener.open(request, timeout=timeout) as response:
                answer = response.read(65535)
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
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        raise SystemExit(_run_self_test())
    with socketserver.ThreadingUDPServer(("127.0.0.1", 53), DNSHandler) as server:
        server.daemon_threads = True
        server.serve_forever()
