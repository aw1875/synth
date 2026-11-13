# Synth's desktop ACP contract

Start `synth acp` and communicate over stdin/stdout with one UTF-8
JSON-RPC 2.0 object per line. The limit is 16 MiB per frame. Stderr is for
diagnostics. Request IDs can be integers or strings, and requests in each
direction have independent ID spaces.

Send `initialize` with `protocolVersion: 1`,
`_meta: {"synth":{"protocol":2}}` and
`clientCapabilities: {"elicitation":{"form":{}}}`. Check both versions
in the reply. This opts into Synth's session notifications in place of
ordinary ACP transcript updates. File and terminal capabilities are omitted,
so the engine handles those operations. Keep reading output while requests
are in flight.

| Method | Parameters and behavior |
| --- | --- |
| `session/new` | Absolute `cwd` and `mcpServers: []`. Returns a `sessionId`. |
| `session/load` | `sessionId`, absolute `cwd`, and `mcpServers: []`. Attaches to an existing host when one is listening. |
| `session/list` | Optional `cwd` for the project. Currently returns up to 50 persisted sessions and no next cursor. Empty sessions are not persisted in the list. |
| `session/prompt` | `sessionId` and `prompt`, an array of content blocks. The Swift client sends `{"type":"text","text":"…"}`. A second prompt during a busy turn is steering. Prompt replies arrive when the turn settles. |
| `session/cancel` | Notification with `sessionId`. Stops the turn. |
| `session/set_mode` | `sessionId` and a `modeId` from the open or load reply. |
| `session/set_config_option` | `sessionId`, `configId` of `model` or `effort`, and `value`. For a model from the catalog, include `_meta.synth.provider` with its provider ID. |
| `_synth/models` | `sessionId`. Returns cached offers and a count of pending provider lookups. The engine sends `_synth/models_updated` as lookups finish. |
| `$/cancel_request` | Notification with `requestId`. Withdraws an individual request. Withdrawing a prompt request leaves the turn running. |

Subscribe before opening a session. `_synth/snapshot` may arrive before the
open or load reply. It replaces the session transcript and status, including
the current stream if present. `dropped` counts earlier messages still stored
by the engine. `_synth/appended` and `_synth/updated` carry a whole message
identified by `seq` within its session. `_synth/stream` adds text and reasoning
to a request number. Show the stream when that number matches the latest
`_synth/status` request. A finalized assistant message supersedes its stream.
`_synth/notice` carries a user-visible message. Every event names its session.

The router can host multiple sessions on the same connection. Replies can
arrive out of order. An incompatible attached endpoint can reject its
handshake. The router reports that error on the corresponding session request.

Synth sends `session/request_permission` with a session, tool call and
available options. Reply with
`{"outcome":{"outcome":"selected","optionId":"<engine option ID>"}}`.
Synth sends `elicitation/create` with a form describing either an `answer`
field or a list of choices and an optional `other` field. Reply with
`{"action":"accept","content":{"answer":"…"}}` or
`{"action":"decline"}`. When the engine withdraws either request, discard it
using its exact RPC ID. This can happen when another client answers first.

Close stdin and continue draining stdout/stderr to disconnect gracefully.
The router applies the engine's existing last-client rules. A reconnect starts
a new router and loads known sessions by ID and working directory. The Swift
client reports each load failure and retains the last visible transcript.
It never replays prompts. Configuration, credentials and persistence stay
with the engine.
