import Foundation
import Testing
@testable import MijiaCore

@Suite(.timeLimit(.minutes(1)))
struct TVBridgeDiscoveryTests {
    @Test("Parses mDNS zone output for Xiaomi/Redmi, Android TV, Google Cast, and filters non-TV AirPlay devices")
    func parsesMDNSZoneOutputAndFiltersAirPlay() {
        let androidOutput = """
        Redmi\\032G\\032Pro\\03227U._androidtvremote2._tcp.local. SRV 0 0 6466 redmi-gpro.local.
        Redmi\\032G\\032Pro\\03227U._androidtvremote2._tcp.local. TXT "fn=Redmi G Pro 27U" "md=Redmi G Pro 27U" "bt=AA:BB:CC:DD:EE:FF"
        """
        let redmi = TVBridgeDiscovery.parseMDNSZoneOutput(
            androidOutput,
            serviceType: "_androidtvremote2._tcp",
            hostResolver: { $0 == "redmi-gpro.local" ? "192.168.1.42" : nil }
        )
        #expect(redmi.count == 1)
        #expect(redmi[0].name == "Redmi G Pro 27U")
        #expect(redmi[0].host == "192.168.1.42")
        #expect(redmi[0].brand == "Xiaomi / Redmi")
        #expect(redmi[0].suggestedDriver == .xiaomi_mitv_6095)
        #expect(redmi[0].port == 6095)
        #expect(redmi[0].macAddress == "aabbccddeeff")

        let airplayOutput = """
        MacBook\\032Pro._airplay._tcp.local. SRV 0 0 7000 macbook.local.
        MacBook\\032Pro._airplay._tcp.local. TXT "model=Mac15,6"
        HomePod._airplay._tcp.local. SRV 0 0 7000 homepod.local.
        HomePod._airplay._tcp.local. TXT "model=AudioAccessory5,1"
        LG\\032OLED\\032C3._airplay._tcp.local. SRV 0 0 7000 lg-c3.local.
        LG\\032OLED\\032C3._airplay._tcp.local. TXT "model=OLED65C3" "manufacturer=LG Electronics"
        """
        let airplay = TVBridgeDiscovery.parseMDNSZoneOutput(
            airplayOutput,
            serviceType: "_airplay._tcp",
            hostResolver: { host in
                switch host {
                case "lg-c3.local": "192.168.1.50"
                default: "192.168.1.99"
                }
            }
        )
        #expect(airplay.count == 1)
        #expect(airplay[0].name == "LG OLED C3")
        #expect(airplay[0].host == "192.168.1.50")
        #expect(airplay[0].brand == "LG")
        #expect(airplay[0].suggestedDriver == .lg_webos_ssap)
        #expect(airplay[0].port == 3001)
    }

    @Test("Parses SSDP DIAL/MediaRenderer responses and UPnP device XML while enforcing private-LAN-only locations")
    func parsesSSDPAndUPnP() {
        let ssdp = """
        HTTP/1.1 200 OK\r
        LOCATION: http://192.168.50.18:49152/description.xml\r
        SERVER: Linux/4.19 UPnP/1.0 MiTV/2.0\r
        ST: urn:dial-multiscreen-org:service:dial:1\r
        USN: uuid:redmi-tv-1::urn:dial-multiscreen-org:service:dial:1\r
        \r
        """
        let parsed = TVBridgeDiscovery.parseSSDPResponse(ssdp, senderHost: "192.168.50.18")
        #expect(parsed?.host == "192.168.50.18")
        #expect(parsed?.location?.absoluteString == "http://192.168.50.18:49152/description.xml")

        let xml = """
        <root><device>
          <friendlyName>书房 Redmi 显示器 &amp; TV</friendlyName>
          <manufacturer>Xiaomi</manufacturer>
          <modelName>Redmi G Pro 27U</modelName>
        </device></root>
        """
        let device = TVBridgeDiscovery.parseUPnPDeviceDescription(xml, host: "192.168.50.18", ssdpServer: parsed?.server, ssdpST: parsed?.st)
        #expect(device?.name == "书房 Redmi 显示器 & TV")
        #expect(device?.brand == "Xiaomi / Redmi")
        #expect(device?.model == "Redmi G Pro 27U")
        #expect(device?.suggestedDriver == .xiaomi_mitv_6095)
        #expect(device?.port == 6095)

        // Public IP, IMDS, loopback, and non-HTTP SSDP locations must be rejected even with a LAN senderHost.
        let publicSSDP = "HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8:8080/desc.xml\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n"
        #expect(TVBridgeDiscovery.parseSSDPResponse(publicSSDP, senderHost: "192.168.50.18") == nil)
        #expect(TVBridgeDiscovery.validatedSSDPLocationURL("http://169.254.169.254/latest/meta-data") == nil)
        #expect(TVBridgeDiscovery.validatedSSDPLocationURL("http://127.0.0.1:8080/desc.xml") == nil)
        #expect(TVBridgeDiscovery.validatedSSDPLocationURL("https://192.168.1.5:8443/desc.xml") == nil)
        #expect(TVBridgeDiscovery.validatedSSDPLocationURL("http://user:pass@192.168.1.5:8080/desc.xml") == nil)
    }

    @Test("Parses Xiaomi HTTP 6095 alive payload and upgrades generic discoveries on merge")
    func parsesXiaomi6095AndMergesByHost() {
        let json = Data(#"{"status":0,"data":{"devicename":"红米显示器","wifimac":"11:22:33:44:55:66","model":"Redmi G Pro 27U"}}"#.utf8)
        let alive = TVBridgeDiscovery.parseXiaomi6095Alive(json, host: "172.16.0.25")
        #expect(alive?.name == "红米显示器")
        #expect(alive?.suggestedDriver == .xiaomi_mitv_6095)
        #expect(alive?.port == 6095)
        #expect(alive?.macAddress == "112233445566")

        // Rejects non-zero status and unrelated JSON payloads.
        #expect(TVBridgeDiscovery.parseXiaomi6095Alive(Data(#"{"status":1,"data":{}}"#.utf8), host: "172.16.0.25") == nil)
        #expect(TVBridgeDiscovery.parseXiaomi6095Alive(Data(#"{"hello":"world"}"#.utf8), host: "172.16.0.25") == nil)
        #expect(TVBridgeDiscovery.parseXiaomi6095Alive(json, host: "8.8.4.4") == nil)

        // Merging a generic DLNA discovery with a confirmed HTTP 6095 hit upgrades the driver and combines sources.
        let generic = TVBridgeDiscoveredDevice(
            name: "172.16.0.25", host: "172.16.0.25", port: 1900,
            brand: "DLNA", model: "MediaRenderer", suggestedDriver: .dlna_dmr, sources: ["SSDP"]
        )
        let merged = TVBridgeDiscovery.mergeDiscovered([generic, alive!])
        #expect(merged.count == 1)
        #expect(merged[0].suggestedDriver == .xiaomi_mitv_6095)
        #expect(merged[0].name == "红米显示器")
        #expect(merged[0].macAddress == "112233445566")
        #expect(merged[0].sources == ["HTTP 6095", "SSDP"])
    }

    @Test("Classifies major TV brands accurately and validates private-LAN hosts")
    func brandClassificationAndHostValidation() {
        #expect(TVBridgeDiscovery.classify(name: "客厅索尼", manufacturer: "Sony", model: "KD-65X90L").driver == .sony_bravia_psk)
        #expect(TVBridgeDiscovery.classify(name: "Bedroom TV", manufacturer: "Samsung", model: "QN55").driver == .samsung_tizen_ws)
        #expect(TVBridgeDiscovery.classify(name: "雷鸟鹤6 Pro", model: "FFALCON").driver == .tcl_ffalcon_tnscreen)
        #expect(TVBridgeDiscovery.classify(name: "Hisense U8K", server: "VIDAA/6.0").driver == .hisense_vidaa_mqtt)
        #expect(TVBridgeDiscovery.classify(name: "Kodi Living", serviceType: "_xbmc-jsonrpc-h._tcp").driver == .kodi_jsonrpc)
        #expect(TVBridgeDiscovery.classify(name: "Apple TV", serviceType: "_airplay._tcp", txt: ["model": "AppleTV14,1"]).driver == nil)

        #expect(TVBridgeDiscovery.validatedLANHost("192.168.1.20") == "192.168.1.20")
        #expect(TVBridgeDiscovery.validatedLANHost("my-tv.local.") == "my-tv.local")
        #expect(TVBridgeDiscovery.validatedLANHost("8.8.8.8") == nil)
        #expect(TVBridgeDiscovery.validatedLANHost("127.0.0.1") == nil)
        #expect(TVBridgeDiscovery.validatedLANHost("169.254.169.254") == nil)
        #expect(TVBridgeDiscovery.validatedConfiguredHost("my-tv.lan") == "my-tv.lan")
        #expect(TVBridgeDiscovery.validatedConfiguredHost("example.com") == nil)

        let gPro = DDCCIDisplayDescriptor(id: "d1", name: "Redmi G Pro 27U", manufacturer: "UNK", model: "G Pro 27U")
        #expect(gPro.isRedmiOrXiaomiMonitor)
    }
}
