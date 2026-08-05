extension IP {
    /// An IPv4 address, which is 32 bits wide.
    public struct V4: Hashable, Sendable {
        /// The logical value of the address: the high byte is the first octet.
        ///
        /// `swift-ip` stored big-endian raw bytes and computed this property.
        /// Arca never read that raw storage, so this type stores the logical
        /// value directly. One consequence is that `description` here is
        /// endian-independent, where `swift-ip`'s was endian-*dependent* by its
        /// own documentation. Arca is macOS-only and macOS is little-endian
        /// everywhere, so the output is identical on every supported platform.
        public var value: UInt32

        /// Creates an address from its logical value.
        public init(value: UInt32) {
            self.value = value
        }

        /// Creates an address from its four octets, first octet first.
        public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
            self.value =
                UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
        }
    }
}

extension IP.V4: Comparable {
    /// Compares two addresses by their logical value.
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

extension IP.V4: CustomStringConvertible {
    /// Formats the address in dotted-decimal notation.
    public var description: String {
        """
        \(self.value >> 24)\
        .\(self.value >> 16 & 0xFF)\
        .\(self.value >> 8 & 0xFF)\
        .\(self.value & 0xFF)
        """
    }
}

extension IP.V4: LosslessStringConvertible {
    /// Parses an address in dotted-decimal notation.
    ///
    /// Requires exactly four `.`-separated fields, each parsed by
    /// `UInt8.init(_:)`. That parser accepts a leading `+` or `-` and leading
    /// zeros, so `010.1.1.1`, `+1.2.3.4` and `1.2.3.-0` all parse. This
    /// leniency is inherited from `swift-ip` 0.3.3 on purpose: rows already
    /// written to Arca's SQLite state came through that parser, so a stricter
    /// reader could fail to load real installed state.
    public init?(_ description: some StringProtocol) {
        guard
            let firstDot = description.firstIndex(of: "."),
            let a = UInt8(description[..<firstDot])
        else { return nil }

        let afterFirst = description.index(after: firstDot)
        guard
            let secondDot = description[afterFirst...].firstIndex(of: "."),
            let b = UInt8(description[afterFirst ..< secondDot])
        else { return nil }

        let afterSecond = description.index(after: secondDot)
        guard
            let thirdDot = description[afterSecond...].firstIndex(of: "."),
            let c = UInt8(description[afterSecond ..< thirdDot])
        else { return nil }

        let afterThird = description.index(after: thirdDot)
        guard let d = UInt8(description[afterThird...]) else { return nil }

        self.init(a, b, c, d)
    }
}
