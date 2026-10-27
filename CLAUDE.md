# Block Bliss

An honest 8×8 block puzzle (Block Blast! Classic rules, none of the manipulation): every dealt set of
three is proven placeable by a solver. A gift app that lives on TestFlight, not the App Store. The
house rules, pipeline and skills come from the gi-os kit, loaded at session start (`.gios/`,
read-only here).

- Code: `BlockBliss/Engine` is pure Swift, also a Swift package (`Package.swift`, `BlockEngine`)
  tested with `swift test`; `Tools/blocksim` runs Monte-Carlo games to check solvability. Both run in
  CI (PRE_TEST). The app target has no XCTest bundle (XCTEST="false").
- Rules, scoring and the generator are specified in SPEC.md and GENERATOR.md: keep them in sync with
  the engine. Every build also goes to the "Friends" TestFlight group (EXTERNAL_GROUPS).
