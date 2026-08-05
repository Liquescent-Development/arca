extension IP {
    /// A CIDR block of IPv4 addresses.
    ///
    /// `swift-ip` made this generic over an `Address` protocol. Arca only ever
    /// instantiated it at `IP.V4`, so the generic parameter is dropped here; a
    /// protocol with a single conformer buys nothing. The `IP` namespace is the
    /// extension point if IPv6 is ever needed.
    public struct Block: Hashable, Sendable {
        /// The network address, already masked to `bits`.
        public let base: V4

        /// The prefix length, in the range `0...32`.
        public let bits: UInt8

        /// Creates a block, masking `base` down to `bits`.
        ///
        /// - Precondition: `bits` is at most 32.
        public init(base: V4, bits: UInt8) {
            precondition(bits <= 32, "IPv4 prefix length out of range: \(bits)")
            self.bits = bits
            self.base = V4(value: base.value & Self.mask(ones: bits))
        }

        /// A mask whose logical high `bits` are 1 and whose remainder is 0.
        static func mask(ones bits: UInt8) -> UInt32 {
            bits == 0 ? 0 : ~UInt32.zero << (32 - UInt32(bits))
        }
    }
}

extension IP.Block {
    /// The closed range of addresses the block covers.
    ///
    /// The upper bound is the block's **broadcast address**, reproducing
    /// `swift-ip` 0.3.3 exactly. Arca's IP allocator treats this bound as
    /// inclusive, which means it can allocate a subnet's broadcast address.
    /// That defect predates this type, is tracked separately, and is
    /// reproduced rather than fixed so the replacement stays
    /// behaviour-identical to what it replaced.
    public var range: ClosedRange<IP.V4> {
        self.base ... IP.V4(value: self.base.value | ~Self.mask(ones: self.bits))
    }

    /// Returns whether `address` falls inside the block.
    public func contains(_ address: IP.V4) -> Bool {
        address.value & Self.mask(ones: self.bits) == self.base.value
    }
}

extension IP.Block: CustomStringConvertible {
    /// Formats the block in CIDR notation.
    public var description: String { "\(self.base)/\(self.bits)" }
}

extension IP.Block: LosslessStringConvertible {
    /// Parses a block in CIDR notation, masking the base address.
    public init?(_ string: some StringProtocol) {
        guard
            let slash = string.lastIndex(of: "/"),
            let base = IP.V4(string[..<slash]),
            let bits = UInt8(string[string.index(after: slash)...]),
            bits <= 32
        else { return nil }

        self.init(base: base, bits: bits)
    }
}
