# AI mixing with OpenRouter

The Mix tab creates a candidate directly in the current REAPER project. Audio
analysis happens locally using ReferenceLab and FFmpeg. A Python process calls
OpenRouter's tool-calling API; native Lua executes allowlisted REAPER operations.
The client uses the standard API directly, with no Agents SDK or cloud service.

## Install

After the main Solo Studio installation:

1. Copy `Mix/worker.py`, `Mix/leveling.py`, `Mix/planning.py`, `Mix/charts.py`, `Mix/visuals.py`, `Mix/spectrogram.py`, and `Mix/Connect OpenRouter.command` into
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

**Advanced settings** controls loudness, the model round limit and a stop threshold based
on reported usage cost. The default maximum loudness target is **−12 LUFS**, with
quieter references lowering the effective target further. Change it from −24 to
−8 LUFS in setup, or **Target … LUFS · Limits…** during review; the setting applies
to the next mix/continuation. Completion uses this target (within 1 LU), not the
raw level of a louder reference master. The mixer is directed to reduce limiter
drive when a result feels over-limited; lowering post-limiter output would leave
the flattened dynamics intact. Source clips and existing user FX remain protected.
The cost threshold
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
Before each fresh render, the bridge runs REAPER's **Item: Set all media online**.
REAPER's inactive-app preference can close source files between agent calls;
programmatic rendering could then produce silence even though playback reopened
them correctly. The bridge leaves that global preference unchanged. Render traces
record this step and the inactive-media setting for diagnosis.

The [local MCP server](../MCP/README.md) exposes start/resume/cancel and diagnostic
tools to Codex. New passes retain append-only worker and REAPER logs, with the
actual guard/timeout/close reason saved separately from generic worker cancellation.
The panel defers its first frame until its launching REAPER action returns, so
recovering a mix does not capture a stale project counter during startup.
Continuing a recovered pass also retires its previous bridge request before the
new worker starts; an old render or effect edit is never replayed on resume.

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
- Full-mix spectrograms use project time horizontally, logarithmic frequency
  vertically and fixed −90…0 dBFS log-band power in color. All overlapping Hann
  FFT windows contribute; stereo channel powers are averaged so anti-phase audio
  does not disappear. Time averaging is bounded to 900 columns, not isolated
  samples. Plots show processed output, including effects, without another render.

**Graphs** now includes **Overview**, **Spectrogram**, **Waterfall** (perspective
height plus color) and **Dynamics** (one-second RMS, sample peaks and crest).
**Open full size** opens the selected PNG. These local views are generated even
when AI visual analysis is off; that switch controls image transmission to the
model. The agent receives the 2D spectrogram alongside existing measured charts;
the waterfall provides an alternate human view of the same data. Neither chart
measures plugin gain reduction or guarantees an audible improvement.
Graphs are snapshots of the last measured full mix, not live playback or A/B.
Existing sessions can use **Generate graphics** to analyze their saved render
without a paid request or new REAPER render. Charts and `graphics.json` stay local.

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
The separate quieter loudness goal takes precedence over reference mastering
level or density. Each full-mix measurement includes signed gaps from the references' median and
their measured range, so the agent can check whether its changes move closer.
For comparable material, the prompt starts with working tolerances of roughly
1 LU from the effective loudness target and 2 dB for broad normalized band balance. These
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
For measurement tools, `full_passage: true` takes precedence over supplied
start/duration fields and uses the selected passage bounds. Invalid field types
are still rejected. Rejected tool requests log their known arguments and reason
locally, including requests that fail before reaching REAPER.

**Vocal and guitar leveling is an explicit part of mixing.** Populated, unmuted
vocal/guitar tracks are identified from their names and routing as required review
targets; the agent can include other sources after inspecting their roles.
Tracks with a static zero fader and no sends are excluded, so unused scratch tracks
do not trigger silent renders. A zero fader with volume automation or sends remains
eligible because it can still contribute audio; quiet nonzero faders also remain.
`analyze_track_levels` checks up to eight sources. Its default `stage=plan` gets
one **full-passage baseline**, then uses up to three short, representative
12–24 second checks after edits. Unchanged sources wait for final verification.
`stage=verify` checks the **entire selected passage at current settings** and is
required for the final review; short checks cannot approve a song. Valid renders
are reused. Local analysis retains every one-second sample; only evidence sent
to the model is reduced, and older dense tables are retired from model context.
It reports active phrase windows, named song
sections, sustained level differences and same-time track-to-mix balance proxies.
The roughly 3 dB review flags identify candidates for attention, not automatic gain
instructions. Silence and very low noise are excluded from active-level medians;
this is not a vocal/bleed detector. Solo-in-place processing means the balance
proxy is affected by shared returns and nonlinear master FX, not a dry-stem ratio.

The agent can preview continuous leveling with **`plan_level_automation`**:
activity-gated, moving power-RMS analysis produces a partial inverse gain curve.
Defaults are 3-second smoothing, 50% correction, +3/−6 dB correction limits and
1.5 dB/second maximum correction slope. It reduces sustained level differences
without trying to flatten every attack. The whole passage or any range of at
least one second can be treated; the target uses the full active performance.
No phrase, bar or section boundary is required. Peaks are displayed for context;
the correction follows RMS, not transient peaks. This uses one-second evidence,
not a note detector or a substitute for compression.

The preview includes a graph, predicted active p90–p10 spread and bounded gain
range. Prediction assumes linear gain; actual shared bus/master processing still
needs a rendered check. JSON and charts are saved in the session analysis folder.
**`apply_level_automation`** applies up to eight current plans together. Plans
become stale after other mix edits, and replaying an applied ID never stacks it.
Silence is gated and existing owned rides are included; quiet bleed can still need
musical judgment. Deliberate quiet sections can be preserved by restricting ranges
or declining a plan. Defaults are agent tool parameters, not new panel sliders.

For an explicit correction such as “+2 dB from 43.2 to 46.2 seconds,”
**`set_phrase_rides`** holds gain across arbitrary start/end seconds with short
ramps, preserving owned rides elsewhere. Despite the name, it has no phrase grid.
These rides can be batched through `apply_mix_batch`. Low-level
`set_trim_automation` remains available for replacing a full owned curve.
The agent uses faders for overall balance and compression for
short-term dynamics, and retain intentional verse/chorus lifts and solos. The goal
is consistent musical prominence, not equal RMS across instruments. Source clips
and pre-existing volume automation are unchanged: rides use a separate post-FX
trim processor, with up to 256 linear points and -12…+6 dB range, including zero-dB
endpoints at the selected passage boundaries. `inspect_project.trim_envelopes`
exposes existing session rides so refinements can preserve and merge them.

After the final edits, each required source needs fresh full-passage evidence and
a `review_level_balance` decision explaining the correction or intentional dynamics.
Attempted mix edits invalidate earlier reviews, including edits in batches.
Completion checks challenge missing/stale leveling reviews even when master LUFS
already matches. Budget limits still apply; missing or unmeasurable evidence is
reported as unverified instead of claiming leveling is complete. No automation is
forced onto an already consistent performance. Per-track reports are saved locally
in `level-balance.json`; decisions and remaining work appear in status and logs.
The new workflow applies to the next mix/continuation; it does not modify an idle
candidate merely by installing the update.

Once ready, press Play and switch **Original** / **Candidate** while listening.
The song keeps playing from the same position; keys **1** and **2** select Original
and Candidate in the Mix tab. Keep and Revert also work during playback. Recording
locks these controls, and **Give feedback…** still requires stopped transport.
Press **G** in the Mix review to open feedback from the keyboard.
These buttons switch actual project levels; **this A/B is not
loudness matched**. LUFS readouts make that difference visible. **Give feedback…**
continues from the current candidate while retaining the original rollback point.
The latest feedback is sent separately from the overall mix direction and replaces
previous pass instructions, so a request to ease limiting does not repeat an old
request to apply leveling.
**Keep mix** accepts a measured candidate below or equal to -1 dBTP. A candidate
with higher peaks needs another pass or manual review; the Keep button remains
unavailable. **Revert** removes session-added effects and restores original
faders/pan, preserving controls you subsequently changed yourself.

The session folder also contains the larger four-panel comparison chart,
complete measurements and render WAVs.

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
  Inspection and limiter readback expose the post-FX master gain and a suggested
  compensated plugin ceiling with 0.1 dB margin. For example, a +2.57 dB master
  fader needs about -3.67 dB at the limiter. This is guidance, not an automatic
  gain change; automated master gain and adapter-range limits are flagged.
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
`Tests/Run level balance checks.lua` renders a quiet/loud/quiet synthetic guitar,
runs the real worker with a scripted model (no API call), writes a phrase ride,
and checks the resulting level spread. It also checks recovered envelope readback,
long envelopes, the +6 dB limit, Original/Candidate, Revert, unchanged clip gain,
zero-fader detection, and post-master-gain limiter guidance using installed
FabFilter Pro-L 2. It checks exact preservation of the user's track/master state.
Close the panel and stop transport first; the test restores the song and reopens
the panel.
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

Continuous leveling was verified on an actual 269-second, 19-track project with
GPT-6 Luna. One 50%/3-second curve per source reduced the measured active one-second
p90–p10 spread from 8.60 to 6.53 dB on guitar and 11.68 to 9.91 dB on vocals.
Full-song output measured −9.8 LUFS and −1.1 dBTP after a further paired overhead
EQ refinement. The pass reached measured review in 7m40s, with 12 full renders,
17 short renders, 19 model rounds and $0.135 reported cost. Short refinement
renders took roughly 2–4 seconds. The preceding pass took 16m17s and 30 full
renders, but these were different continuations, not a controlled speed benchmark.
Original/Candidate remained available; the test did not Keep or save the song.
The Python suite has 84 passing checks, including full-resolution evidence,
curve/gap/range behavior, preview/apply staleness, idempotence, partial failure,
short diagnostic selection and mandatory final verification.

On the development machine, 47 native integration checks passed, including the
complete asynchronous worker/REAPER/render/analyzer/chart loop, compressor makeup,
master limiting, source-peak reading and master-FX rollback. Python checks cover the
worker and completion handling; 87 Lua checks cover A/B and review controls, with another
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
