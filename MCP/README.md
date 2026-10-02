# Solo Studio MCP

A local stdio MCP server for Codex. It controls the existing Solo Studio mix
workflow through a narrow REAPER main-thread inbox and reads private diagnostics.
No HTTP listener or separate credentials are needed. The paid mixer continues to
use its existing local OpenRouter connection and model settings.

## Install

1. Update all Lua files in REAPER's `Scripts/Solo Studio/` folder and copy
   `Mix/worker.py` into its `Mix/` subfolder. Reload the Solo Studio panel when no
   mix is running. The new `solo_mcp.lua` must be installed alongside the panel.
2. With Node 20 or newer, run `npm ci --ignore-scripts` in this `MCP` folder.
3. Register the absolute server path with Codex:

   ```sh
   codex mcp add solo-studio -- /absolute/path/to/node /absolute/path/to/reaper-solo-studio/MCP/server.mjs
   codex mcp get solo-studio
   ```

   Codex's app and CLI share MCP configuration. Refresh/restart the client if an
   already-open conversation does not list the new tools. See the
   [official MCP configuration documentation](https://developers.openai.com/codex/mcp/).

Keep this repository at its configured path, or update the Codex entry after
moving it. Runtime dependencies and private logs are not committed.

## Tools

| Tool | Purpose |
| --- | --- |
| `get_studio_status` | Active project ID/name, transport, heartbeat, current mix and defaults |
| `list_mix_sessions` | Recent sessions across projects, including unfinished passes |
| `list_mix_references` | Already analyzed reference titles/IDs |
| `start_mix` | Start using panel defaults or explicit model, direction, bounds, references and limits |
| `resume_mix` | Continue an existing candidate with feedback and a fresh pass budget |
| `cancel_mix` | Request cancellation, preserving candidate changes for review |
| `get_mix_status` | Progress, current operation, measurements, cost, worker liveness and stop reason |
| `read_mix_log` | Paginated worker or REAPER events; byte cursors support following new entries |
| `get_mix_diagnostics` | Combined failure, guard context, last bridge request/response and recent logs |

Read studio status before starting or resuming. Every mutation targets the exact
active project ID; resume/cancel also require its session ID. Start refuses an
unfinished session instead of replacing it. All tabs must be stopped for start
and resume. External project edits and Original/Candidate protections still
apply. Starting/resuming sends the existing mix context to OpenRouter and spends
credits; `stop_after_usd` is a reported-cost stopping threshold, not a hard cap.
Start/resume also accept `target_lufs` (−24 to −8, default −12), a maximum loudness
target that quieter references can lower further. Status/diagnostics expose the
effective goal separately from raw reference loudness. Normal peak checks remain.
The MCP server cannot Keep, Revert, delete, save a project, or run arbitrary code.

Start returns a session ID immediately; follow it with status/log calls. Use a
stable `request_id` UUID when retrying a lost command response. Completed receipts
are replayed, not the command. Expired requests cannot execute later. An ambiguous
receipt after a crash requires inspecting status rather than blindly launching
another pass. Cancellation waits for a current render/API call to return.

The panel must be open to control REAPER. Historical logs remain readable when it
is closed. A stale heartbeat alone does not prove a crash: an offline render or
modal dialog can block REAPER's UI thread.

## Diagnose a stopped mix

1. Get the session ID from studio status or the session list.
2. Read `get_mix_diagnostics`. Check `panel_stop` first, then `failure`,
   `completion_reason`, `activity`, and the latest bridge request/reply.
3. Read `read_mix_log` with `source: "worker"` and `source: "reaper"`. Omit cursor
   for recent entries, use `0` for the beginning, or reuse `next_cursor` to follow.

New passes append worker messages, tool requests/results, model-response summaries,
measurements, failures and pass IDs to `events.jsonl`. REAPER appends render
start/return, engine restarts and guard stops to `bridge-events.jsonl`. A separate
`panel-stop.json` preserves the actual panel stop even if the worker subsequently
reports generic cancellation. Playback during a pass produces `guard_rejected`
with a nonzero transport; project edits include actual and expected versions.
`worker.json` and an OS file lock prevent overlapping workers on one session.

Logs do not include provider headers, keys, raw model reasoning, or audio. They
do include song/track names, directions, settings and model output, so they stay
private under `~/Library/Application Support/Solo Studio/Mix`. The server exposes
only known diagnostic files under valid session IDs and refuses symlinked files.
Older sessions only have their previously saved status messages; missing history
cannot be reconstructed. Logs identify a processing failure but do not by
themselves prove which plugin caused silence.

## Validation

`npm test` covers the real MCP handshake, tool schemas, log cursors, path bounds,
expired commands and replay protection. The Python suite covers durable failure
logs and worker locking; `Tests/MCP controls.lua` covers native dispatch guards.

`Tests/Run MCP checks.lua` exercises the full MCP → native panel → worker → render
path in a disposable REAPER project with synthetic audio and no hardware outputs.
It starts a mix, resumes it, injects a playback state to verify the saved guard
reason, resumes again and cancels. It verifies original track/master preservation
and reopens Solo Studio. Close the panel and stop all transport first. Generate
`Tests/mix-tone.wav` using the command in `Mix/README.md`. The fixture substitutes
a scripted model response; it makes no provider request and spends no credits.
