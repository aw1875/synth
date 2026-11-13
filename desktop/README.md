# Synth macOS client foundation

The Synth desktop client targets macOS 26 or later. Its Swift package
communicates with the Zig engine through a single `synth acp` subprocess. See [the wire contract](../docs/desktop-acp.md)
for the method and lifecycle details.

From the repository root, build and run the offline tests:

```sh
zig build test
(cd desktop && swiftlint lint --strict)
swift test --package-path desktop
```

Run the integration test with a ReleaseSafe engine built from this checkout:

```sh
zig build -Doptimize=ReleaseSafe
python3 desktop/Tests/Fixtures/fake_provider.py zig-out/bin/synth
```

The test starts a provider on an ephemeral loopback port and creates two
temporary projects with a dedicated database, config and socket directory.
It verifies that approvals and questions route to their own sessions, that
another client can answer a pending question, and that steering, cancellation
and reload work through the actual router. Plain `swift test` skips this
scenario when the harness has not supplied an engine.

Regenerate the checked-in wire fixture after an intentional protocol change:

```sh
zig build acp-fixtures > desktop/Tests/SynthClientTests/Fixtures/stream.jsonl
```
