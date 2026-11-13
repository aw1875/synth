# Synth for macOS

The Synth desktop client communicates with the Zig engine through a single
`synth acp` subprocess. See [the wire contract](../docs/desktop-acp.md)
for the method and lifecycle details.

## Build and run

The app supports Apple Silicon Macs running macOS 26 or later. Building it
requires Xcode 26 or later, Zig 0.16, and network access to resolve the Swift
packages on the first build.

From the repository root:

```sh
desktop/Scripts/build-app.sh
```

On Apple Silicon, `nix develop .#desktop` provides Zig, ZLS, and SwiftLint.
Install and select Xcode separately so the build can use its macOS SDK.

Open `desktop/DerivedData/Build/Products/Release/Synth.app` in Finder. The
app bundles the engine and uses the same Synth configuration and credentials
as the terminal client. If you need to configure a provider, run `synth` in
Terminal first. For Xcode builds, set the `SYNTH_ENGINE` build setting to a
ReleaseSafe executable built from this checkout.

Choose **New Conversation** to chat without opening a project. Standalone
chats use `~/Library/Application Support/Synth/Conversations` as their working
directory and appear under **Conversations**. To work in a folder, choose
**Open Project** or use the plus button next to an existing project.

The sidebar shows when a background conversation is running or needs input.
Select **More Conversations** to load older chats. Press
**Command–Return** to send or steer, or click **Stop** to cancel the current turn.

## Development

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
