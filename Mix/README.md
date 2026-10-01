# AI mixing with OpenRouter

The Mix tab creates a candidate directly in the current REAPER project. Audio
analysis happens locally using ReferenceLab and FFmpeg. A Python process calls
OpenRouter's tool-calling API; native Lua executes allowlisted REAPER operations.
The client uses the standard API directly, with no Agents SDK or cloud service.

## Install

After the main Solo Studio installation:

1. Copy `Mix/worker.py`, `Mix/charts.py`, `Mix/visuals.py`, and `Mix/Connect OpenRouter.command` into
   `Scripts/Solo Studio/Mix/` in REAPER's resource folder.
   Keep the main Lua modules updated too, including `solo_mix_visuals.lua`.
2. Copy `ReferenceLab/analyze.py` into `Scripts/Solo Studio/ReferenceLab/`.
3. Copy `Effects/Mix trim.jsfx` into `Effects/Solo Studio/`.
4. Install FFmpeg/ffprobe and the Python dependencies in `ReferenceLab/requirements.txt`
   for `/usr/bin/python3`. Tested on macOS with Python 3.9, NumPy 1.26, Matplotlib
   3.9 and FFmpeg 7.1.1. The main panel has no Python dependency until Mix is used.
5. Make the connection launcher executable: `chmod +x "Connect OpenRouter.command"`.
6. Reopen Solo Studio, choose **Mix → Mix with AI → Connect / change key**.
   Enter the key in Terminal's hidden prompt. After validation, click
   **Refresh connection** in Solo Studio.

Credentials are stored in `~/Library/Application Support/Solo Studio/Mix/credentials.json`
with permissions 600, inside a directory with permissions 700. They are not stored
in the REAPER project, source tree, command-line arguments or session logs. This
is a protected local file, not encrypted Keychain storage. An inherited
`OPENROUTER_API_KEY` environment variable also works and takes precedence.

## Use

Stop transport and clear track solos. Choose up to two saved references, or
**Analyze new…** to measure another local recording. Choose a time selection or
full-song scope (3 seconds to 10 minutes). Enter mix direction if desired.
The **AI model** dropdown defaults to **GPT-6 Luna** (`openai/gpt-6-luna`). It
shows a dozen recent tool-capable models, using OpenRouter's intelligence-sorted
catalog with provider diversity. Only releases from the last 180 days are listed
(the default stays eligible); batch routes are excluded. This is a convenient
shortlist, not a ranking of audio-mixing quality. Catalog prices are shown per
million input/output tokens; provider, caching and long-context rates can differ.
The list refreshes in the background once a day when setup is opened. **Refresh
models** updates it immediately without a key or a paid model call. Offline, the
last successful list remains available. Selecting a model saves it for future
sessions; refreshing never silently changes that selection. **Enter model ID…**
at the end of the dropdown supports models outside the shortlist. Press **O** in
mix setup to open the dropdown from the keyboard.

**Advanced settings** controls the model round limit and a stop threshold based
on reported usage cost. That threshold
is checked *after* each response, so it is not a guaranteed billing cap.

**Create candidate mix** measures the original, runs the tool loop, and measures
the final candidate. Leave the transport stopped while it works. Rendering uses
REAPER's native offline render dialog, which can be cancelled. Network calls and
analysis run outside REAPER's UI thread.

For passages longer than 45 seconds, routine AI mix and track checks default to
the same energetic 30-second window, selected from the original level envelope.
The agent can request a different start/duration to check another section, or
`full_passage=true` for the whole selection. Measurements identify their exact
project bounds; short-window loudness is not presented as whole-song loudness.
Original, completion and final-review checks always cover the entire selected
passage. Only full-passage measurements feed the review meters and A/B charts.

Repeated measurements of the same scope and unchanged mix reuse the rendered WAV
and its analysis. Every request still checks that the project has not been edited
externally. Any attempted mixing edit or A/B switch invalidates all cached renders
(including solo contributions through shared buses/master FX); recovery starts
with an empty cache. Cancelled/incomplete renders are never cached as valid
measurements. The status feed separates rendering from analysis and reports their
elapsed times; session status also saves measurement timings for diagnosis.

Silent or unmeasurable output is a failed measurement, not 0 LUFS. Both render
and analysis caches are cleared. For a failed mix measurement the worker restarts
the audio engine once (only with transport stopped in every project), then renders
the same passage again without changing mix settings. Persistent full-passage
failure stops the pass; a silent diagnostic window blocks mix edits until another
active window measures successfully. Empty track contributions return a tool error
without restarting audio. The review panel marks a failed candidate unverified,
disables Keep, and leaves Original/Revert available. Local failure details are
saved to `failed-measurement.json`. This handles intermittent processing failures;
successful real-time playback alone does not validate an offline render.

The [local MCP server](../MCP/README.md) exposes start/resume/cancel and diagnostic
tools to Codex. New passes retain append-only worker and REAPER logs, with the
actual guard/timeout/close reason saved separately from generic worker cancellation.

**Visual analysis** is on by default and can be disabled in mix setup. With an
image-capable model, the worker attaches small PNG evidence charts to its model
requests alongside the numeric measurements:

- Source-clip overviews use REAPER's cached take peaks, without a render. Only
  unmuted items in playing lanes are shown, with up to 16 tracks per page. Track
  waveforms are scaled independently; they describe source activity, not processed
  mix balance. MIDI and unavailable peaks are marked, never inferred to be silence.
  Initial overviews cover up to 48 tracks; the `view_arrangement` tool can page
  through other tracks. Time/item limits mark incomplete overviews explicitly.
- Processed charts read existing render WAVs and show the peak-preserving waveform,
  level envelope, normalized spectrum/reference curves and stereo energy. Axes use
  absolute project seconds. Solo-track charts include routing, shared returns and
  master processing, matching the measurements. A chart does not require another
  audio render. Unchanged render charts are reused.

At most four images are retained in model context; older images are replaced by
text notices while numerical results remain. Charts are saved in the session's
`visuals/` folder, accessible through **Show analysis files**. They are transmitted
as PNG data in memory, not public image URLs or screenshots. Image payloads are
not written into chat logs. Normal OpenRouter image-input billing applies.

The model picker labels confirmed models as **vision** or **numbers only**.
Custom models use a public capability lookup. If support is absent or cannot be
verified, the same selected model continues with numerical measurements and the
status feed explains the fallback. No model is silently substituted. Chart
generation failures also leave numerical analysis available. The agent is told
to use images to locate patterns, then verify decisions using measurements; an
image is not evidence that it heard the song or judged vocal intelligibility.

The agent treats the starting session as a rough, unmixed balance unless your
direction says otherwise. Selected references are active targets for broad EQ,
loudness, dynamic density and stereo presentation. It can make substantial changes;
preserving a performance does not mean preserving its starting fader levels.
Each full-mix measurement includes signed gaps from the references' median and
their measured range, so the agent can check whether its changes move closer.
For comparable material, the prompt starts with working tolerances of roughly
2 LU for integrated loudness and 2 dB for broad normalized band balance. These
are adjustable goals, not guarantees or literal EQ settings. Different arrangements
and song sections require judgment. The agent must report remaining gaps and tool
limits rather than claiming an unchanged rough mix is finished.
The loop checks a proposed completion against a full-passage measurement of the
current mix (reusing a render only if no settings have changed) and can challenge it
up to three times when large loudness/tonal gaps remain. Empty or truncated model
responses are retried (at most twice), not accepted as completion; truncated tool
batches are not applied. Requests allow 8,000 output/reasoning tokens, and the same
configured round and reported-cost limits still apply. Unreached reference targets
remain visible in review; you can still audition and keep a result you prefer.
Up to 32 tool calls execute sequentially per model response. An oversized batch
gets a request to split it instead of terminating the session.
The agent can also use **apply_mix_batch** for up to 64 edits in one tool call,
including adding and configuring ten EQs without waiting for another model round.
An added effect can have a batch-local `save_as` name, which later operations use
as `$name`; returned effect GUIDs are used on subsequent passes. Argument and alias
validation covers the entire batch before any edits. Native operations still run
sequentially with the existing checks and Undo entries. If an operation fails,
execution stops and reports exactly which edits completed, the created effect IDs,
the failed operation, and the skipped remainder. Completed edits remain applied
and are included in normal Original/Candidate/Revert behavior.

**inspect_project** already returns all track settings together. **inspect_effects**
reads up to 16 effect parameter pages in one request. **measure_tracks** compares
up to 16 track contributions over the same diagnostic window, custom range, or full
passage; it returns a comparison table and individual numeric profiles. Each track
still needs a sequential processed render unless its result is cached. Shared
returns/master processing are included, so these contributions are not additive
dry stems. Individual measurement failures are reported alongside successful results.

The agent is directed to plan coordinated balance and EQ/dynamics/automation passes,
apply meaningful measured targets across tracks, then measure the combined result.
Small corrections are reserved for small remaining gaps. The batch tools reduce
model round trips; they do not remove rendering cost or the 24-added-effect limit
(including trim processors), per-operation bounds, or normal bridge-call budget.
Rejected track-measurement requests return an error for the model to correct;
they do not terminate the whole pass. Silent or unmeasurable audio is explicitly
reported as a failure, never as meeting the reference targets.

Once ready, press Play and switch **Original** / **Candidate** while listening.
The song keeps playing from the same position; keys **1** and **2** select Original
and Candidate in the Mix tab. Keep and Revert also work during playback. Recording
locks these controls, and **Give feedback…** still requires stopped transport.
Press **G** in the Mix review to open feedback from the keyboard.
These buttons switch actual project levels; **this A/B is not
loudness matched**. LUFS readouts make that difference visible. **Give feedback…**
continues from the current candidate while retaining the original rollback point.
**Keep mix** accepts a measured candidate below or equal to -1 dBTP. A candidate
with higher peaks needs another pass or manual review; the Keep button remains
unavailable. **Revert** removes session-added effects and restores original
faders/pan, preserving controls you subsequently changed yourself.

**Graphs** toggles native spectrum and RMS-envelope plots; the session folder
contains a larger four-panel chart, complete measurements and render WAVs.

The agent's fader, pan and effect settings apply across the track, even when
measurement uses an excerpt. Trim automation is constrained to the excerpt with
zero-dB endpoints. Check the full song before committing a mix based on one passage.

Unfinished mixes belong to their own projects. Switching songs or reopening Mix
finds that project's saved journal; an unfinished candidate in another song does
not block a new mix. Existing journals from the older global-session pointer are
discovered automatically. Saved songs match by project path; unsaved tabs also
need matching track GUIDs. Keep/Revert resolves only the current song's session.
Closing the panel (including a native project-tab switch) cancels a running pass
and preserves its current sound and local journal. The Projects view still waits
for an active pass to stop before switching. Returning to a completed candidate resumes review;
an interrupted pass can be continued with **Give feedback…** or reverted.
When tracks, faders, or effects have changed, **Start a new mix** opens setup
from the current sound without undoing those edits. The old journal and analysis
remain saved. **Revert previous pass** instead removes that pass's added effects
and restores only fader/pan controls that have not been manually changed.
Added or removed tracks no longer misidentify a saved song as another project.
Refinement reuses the session's existing effect IDs and every render has a unique
filename, including after recovery. A cancelled render cannot reuse an old WAV.
A second project cannot start a
new session while the first has an unresolved journal. Keep/revert does not save
the song automatically; use your normal REAPER save workflow.

## Tools and limits

- Project inspection includes track GUIDs, names, levels, pan, mute/solo, parents,
  sends, regions, existing FX names and a filtered installed-plugin inventory.
- Track volume is bounded to -90…+24 dB, without a cap relative to the rough mix. Pan supports
  classic/balance modes; dual/stereo pan and existing volume/pan automation are
  protected. Separate trim automation can ride a track without replacing its
  existing volume envelope.
- ReaEQ supports 20 Hz–20 kHz and ±12 dB. ReaComp supports thresholds down to
  -60 dB, ratios up to 20:1, and explicit 0–6 dB makeup gain. Both have physical-unit
  adapters with parameter-layout and formatted-readback validation.
- Session-owned effects can be added to `MASTER`, including EQ, compression and
  FabFilter Pro-L 2. Its calibrated adapter sets 0–24 dB gain, a -12…-1 dBTP
  ceiling, true-peak limiting on, 2x oversampling and unity gain off. The master
  fader and pre-existing master effects stay unchanged. Original/Candidate and
  Revert include the session's master effects. The full render verifies output
  after the master fader; a limiter setting alone does not guarantee final peaks.
- New instances of ReaEQ, ReaComp, FabFilter and UADx VST/VST3 effects are available.
  Existing FX are read-only. Parameters are inspected in pages of 96 with actual
  names/ranges/normalized values/formatted readbacks. Each normalized move is
  limited to 0.20. The agent must establish the mapping before using it.
- Third-party discovery is not a license/load test or a calibrated hardware
  emulation adapter. UAD DSP-only plugins, arbitrary FX, sends/routing edits,
  item edits and edits to pre-existing FX are outside this version's tools.
- Full-mix and solo-in-place contribution renders run through routing and master
  processing. Solo measurements include shared returns; they are not dry stems.
- Analysis includes integrated LUFS, true peak, LRA, RMS, crest, spectrum,
  mid/side energy, correlation and one-second level envelopes. Graphs and complete
  measurements are saved in the local session folder. There is no real-time RTA
  or model audio listening in this version.
- Reference spectra are normalized energy distributions, not perceptual
  equal-loudness curves. Reference loudness is a target, subject to the -1 dBTP
  output ceiling, musical dynamics and available controls; reference peaks above
  that ceiling are not copied. Source balancing and tonal work come before final
  master compression/limiting; matching loudness alone is not a completed mix.
- 24-bit render output makes clipping a failed candidate rather than preserving
  above-full-scale samples. A final true peak above -1 dBTP prevents Keep.
- Edits/transport changes stop tool execution. Tool schemas, finite bounds and
  plugin ownership are enforced in code; model instructions alone do not enforce
  these rules. A pass defaults to 60 model rounds, configurable from 1–100 in
  Advanced settings or the review screen's Pass limits. A round is one model
  response, potentially containing several tool calls. It can finish early.
  Continue mixing starts another pass from the candidate using the current
  limits; Give feedback does the same with your direction. Both preserve the
  original A/B snapshot and reuse owned effects. The reported-cost stop applies
  separately to each pass (default $2), checked after each response.
  Three consecutive rounds in which every tool fails pause for review; errors
  appear in the log. Requests have timeouts, at most 640 bridge calls per worker
  pass and 160 renders per bridge session. Cached measurements do not use renders.

OpenRouter receives track names/settings, selected reference metrics, user mix
direction/feedback, tool results, decision messages and, with visual analysis
enabled, measured source-overview and processed-audio charts. Audio, source file paths,
credentials and full project files are not submitted. Provider routing requests
`data_collection: deny` and parameter support; this is not a promise of zero data
retention. Choose a provider/model consistent with your own privacy requirements.
Only short model explanations and actual tool progress are shown, not private
reasoning tokens. No candidate quality or professional result is guaranteed by a
spectrum match.

## Validation

`python3 -m unittest discover -s Mix -p 'test_*.py' -v` tests protocol, typed
arguments, cancellation, local credentials, profile minimization, final metering
and failure paths. Batch checks include creating ten configured EQs in one model
response, whole-plan validation, effect-alias scope/ownership, partial failure,
budget/cancellation, bulk effect inspection and same-window track comparisons.
`Tests/Run mix batch checks.lua` exercises ten stock EQs in one real batch,
bulk parameter inspection, two processed track measurements and their cache,
plus Original/Candidate/Revert in a silent disposable project. It requires
`Tests/mix-tone.wav`, stopped transport, and the Solo Studio panel closed; it
restores the original song, checks its track contents, and reopens the panel.
The scripted worker makes no network/model calls.
`Tests/Run render recovery checks.lua` uses the same synthetic fixture and
requirements. It injects one valid-length silent WAV, then checks that the real
worker clears both caches, restarts the stopped engine once, renders audible
output, and reaches measured review without changing candidate settings. Python
tests separately cover persistent silence, unavailable audio, diagnostic edit
locks, silent tracks, and genuine numeric 0 LUFS. Lua review checks cover the
unverified label and Keep/Original/Revert availability after failure.
`Tests/Run mix checks.lua` uses an isolated REAPER tab and a
synthetic sine, with all hardware outputs removed. It checks real native effects,
automation, fader/pan edits, render setting restoration, A/B, rollback, manual-edit
preservation and recovery. A 274-second synthetic passage checks exact diagnostic
bounds, cache invalidation and separate track/mix caches, saving local timings to
`Tests/mix-performance.json`. It then runs `test_native_worker.py` through the real
file bridge and analyzer with a scripted model response and **no network call**.
The expanded fixture requires installed FabFilter Pro-L 2 and checks a level lift
of more than 10 LU while retaining the -1 dBTP final peak ceiling.
The fixture is generated with:

```
ffmpeg -f lavfi -i 'sine=frequency=1000:duration=8:sample_rate=48000' -ac 2 Tests/mix-tone.wav
```

Live paid-model behavior requires the user's OpenRouter key and is a separate
validation from these deterministic tests.

On the development machine, 47 native integration checks passed, including the
complete asynchronous worker/REAPER/render/analyzer/chart loop, compressor makeup,
master limiting, source-peak reading and master-FX rollback. Thirty Python checks cover the worker
and completion handling; 87 Lua checks cover A/B and review controls, with another
18 covering recovery and 11 covering source-overview scope/pagination. Visual
checks verify peak-preserving PCM reduction, absolute chart times, image protocol
ordering, bounded context, capability fallback and no extra audio renders.
A live GPT-6 Luna request using only a synthetic chart correctly identified its
track label and distinguished source peaks from processed mix levels. This verifies
image/tool compatibility, not the quality of an AI mix. During
testing, REAPER 7.55 hit a macOS accessibility crash when the Actions window was
closed by an accessibility press on Run/close. Running the test with **Run** and
leaving Actions open avoided that interaction. No production mixer call uses the
Actions window.
