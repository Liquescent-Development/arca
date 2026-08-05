import Testing

@testable import ArcaIP

@Suite("IP.V4")
struct V4Tests {
    @Test("parses dotted-decimal notation")
    func parsesDottedDecimal() {
        #expect(IP.V4("172.18.0.1")?.value == 0xAC12_0001)
        #expect(IP.V4("0.0.0.0")?.value == 0x0000_0000)
        #expect(IP.V4("255.255.255.255")?.value == 0xFFFF_FFFF)
        #expect(IP.V4("127.0.0.1")?.value == 0x7F00_0001)
    }

    @Test("rejects malformed input")
    func rejectsMalformed() {
        #expect(IP.V4("1.2.3") == nil)
        #expect(IP.V4("1.2.3.4.5") == nil)
        #expect(IP.V4("1.2.3.256") == nil)
        #expect(IP.V4(" 1.2.3.4") == nil)
        #expect(IP.V4("1.2.3.4 ") == nil)
        #expect(IP.V4("") == nil)
        #expect(IP.V4("bogus") == nil)
    }

    // These three are inherited leniency, not oversights. swift-ip 0.3.3 parsed
    // each octet with UInt8.init(_:), which accepts a leading sign and leading
    // zeros. Arca's SQLite rows were written by that parser, so tightening this
    // risks failing to load real installed state. See spec section 6.
    @Test("reproduces swift-ip's parser leniency deliberately")
    func reproducesLeniency() {
        #expect(IP.V4("010.1.1.1")?.value == 0x0A01_0101)
        #expect(IP.V4("+1.2.3.4")?.value == 0x0102_0304)
        #expect(IP.V4("1.2.3.-0")?.value == 0x0102_0300)
    }

    @Test("formats dotted-decimal notation")
    func formatsDottedDecimal() {
        #expect(String(describing: IP.V4(value: 0xAC12_0001)) == "172.18.0.1")
        #expect(String(describing: IP.V4(value: 0x0000_0000)) == "0.0.0.0")
        #expect(String(describing: IP.V4(value: 0xFFFF_FFFF)) == "255.255.255.255")
        #expect(String(describing: IP.V4(value: 0x7F00_0001)) == "127.0.0.1")
    }

    @Test("octet initialiser puts the first octet in the high byte")
    func octetInitialiser() {
        #expect(IP.V4(172, 18, 0, 1).value == 0xAC12_0001)
        #expect(String(describing: IP.V4(192, 168, 1, 254)) == "192.168.1.254")
    }

    @Test("round-trips value through description")
    func roundTrips() {
        for value: UInt32 in [0, 1, 0x0102_0304, 0xAC12_0001, 0x7F00_0001, .max] {
            let address = IP.V4(value: value)
            #expect(IP.V4(String(describing: address))?.value == value)
        }
    }

    @Test("orders by logical value")
    func orders() {
        #expect(IP.V4("10.0.0.1")! < IP.V4("10.0.0.2")!)
        #expect(IP.V4("9.255.255.255")! < IP.V4("10.0.0.0")!)
        #expect(IP.V4("1.2.3.4")! == IP.V4("1.2.3.4")!)
        #expect(IP.V4("1.2.3.4")! != IP.V4("1.2.3.5")!)
    }
}
