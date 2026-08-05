import Testing

@testable import ArcaIP

@Suite("IP.Block")
struct BlockTests {
    @Test("parses CIDR notation")
    func parsesCIDR() {
        let block = IP.Block("172.18.0.0/16")
        #expect(block?.base.value == 0xAC12_0000)
        #expect(block?.bits == 16)
        #expect(String(describing: block!) == "172.18.0.0/16")
    }

    @Test("masks the base address on construction")
    func masksBase() {
        // swift-ip's `/` operator zero-masks, so a non-canonical base is
        // silently canonicalised rather than rejected.
        #expect(IP.Block("172.18.0.5/16")?.base.value == 0xAC12_0000)
        #expect(String(describing: IP.Block("192.168.1.77/24")!) == "192.168.1.0/24")
        #expect(IP.Block(base: IP.V4("10.9.8.7")!, bits: 8).base.value == 0x0A00_0000)
    }

    @Test("rejects malformed input")
    func rejectsMalformed() {
        #expect(IP.Block("172.18.0.0/33") == nil)
        #expect(IP.Block("172.18.0.0") == nil)
        #expect(IP.Block("bogus/16") == nil)
        #expect(IP.Block("172.18.0.0/") == nil)
        #expect(IP.Block("/16") == nil)
        #expect(IP.Block("") == nil)
    }

    @Test("range lower bound is the network address")
    func rangeLowerBound() {
        #expect(IP.Block("172.18.0.0/16")!.range.lowerBound.value == 0xAC12_0000)
        #expect(IP.Block("10.0.0.0/8")!.range.lowerBound.value == 0x0A00_0000)
    }

    // The upper bound is the BROADCAST address, not broadcast - 1. This
    // reproduces swift-ip 0.3.3 exactly and is asserted here so the behaviour
    // cannot drift silently.
    //
    // It is not an endorsement. WireGuardNetworkBackend.swift comments that
    // this bound is "broadcast - 1 already"; that comment is wrong, and because
    // Arca's allocator treats the bound as inclusive it can hand a container
    // its subnet's broadcast address. Tracked as a separate Arca issue, and
    // deliberately not fixed here so this replacement stays behaviour-identical.
    @Test("range upper bound is the broadcast address, reproducing swift-ip")
    func rangeUpperBoundIsBroadcast() {
        #expect(IP.Block("172.18.0.0/16")!.range.upperBound.value == 0xAC12_FFFF)
        #expect(IP.Block("10.0.0.0/8")!.range.upperBound.value == 0x0AFF_FFFF)
        #expect(IP.Block("192.168.1.0/24")!.range.upperBound.value == 0xC0A8_01FF)
    }

    @Test("handles the /0 and /32 boundaries")
    func boundaries() {
        let all = IP.Block("0.0.0.0/0")!
        #expect(all.range.lowerBound.value == 0x0000_0000)
        #expect(all.range.upperBound.value == 0xFFFF_FFFF)
        #expect(all.contains(IP.V4("8.8.8.8")!))

        let host = IP.Block("1.2.3.4/32")!
        #expect(host.range.lowerBound.value == 0x0102_0304)
        #expect(host.range.upperBound.value == 0x0102_0304)
        #expect(host.contains(IP.V4("1.2.3.4")!))
        #expect(!host.contains(IP.V4("1.2.3.5")!))
    }

    @Test("containment checks the masked prefix")
    func containment() {
        let block = IP.Block("172.18.0.0/16")!
        #expect(block.contains(IP.V4("172.18.0.0")!))
        #expect(block.contains(IP.V4("172.18.5.9")!))
        #expect(block.contains(IP.V4("172.18.255.255")!))
        #expect(!block.contains(IP.V4("172.19.5.9")!))
        #expect(!block.contains(IP.V4("172.17.255.255")!))
    }

    @Test("is hashable by base and prefix length")
    func hashable() {
        #expect(IP.Block("10.0.0.0/8") == IP.Block("10.0.0.0/8"))
        #expect(IP.Block("10.0.0.0/8") != IP.Block("10.0.0.0/16"))
        #expect(Set([IP.Block("10.0.0.0/8"), IP.Block("10.0.0.0/8")]).count == 1)
    }
}
