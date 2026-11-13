#!/usr/bin/env python3
"""Guest-only loopback DNS over HTTPS; no access to the host's DNS service."""
import socketserver
import struct
import urllib.request


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, connection = self.request
        if len(packet) < 12:
            return
        request = urllib.request.Request(
            "https://1.1.1.1/dns-query", data=packet,
            headers={"Content-Type": "application/dns-message",
                     "Accept": "application/dns-message"}, method="POST")
        try:
            # Never use an environment proxy or a hostname requiring DNS bootstrap.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=10) as response:
                answer = response.read(65535)
        except Exception as error:
            print(f"DNS upstream failed: {error}", flush=True)
            # Echo the question with QR, RD, RA and SERVFAIL set.
            answer = packet[:2] + struct.pack("!H", 0x8182) + packet[4:]
        connection.sendto(answer, self.client_address)


if __name__ == "__main__":
    with socketserver.ThreadingUDPServer(("127.0.0.1", 53), DNSHandler) as server:
        server.daemon_threads = True
        server.serve_forever()
