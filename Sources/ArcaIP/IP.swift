/// Namespace for IP addressing types.
///
/// This target replaced `swift-ip` 0.3.3, which Arca used for exactly two
/// types. Its own `IP` target had no dependencies, but the package carried
/// five more that pinned commits which no longer exist upstream, so the
/// pinned Arca tree could not be built from a cold cache.
///
/// Behaviour is reproduced exactly rather than improved. The design and the
/// evidence live in the Gas Can repository at
/// `docs/superpowers/specs/2026-08-05-arca-internal-ip-type-design.md`.
public enum IP {}
