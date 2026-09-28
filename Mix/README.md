# AI mixing with OpenRouter

The Mix tab creates a candidate directly in the current REAPER project. Audio
analysis happens locally using ReferenceLab and FFmpeg. A Python process calls
OpenRouter's tool-calling API; native Lua executes allowlisted REAPER operations.
The client uses the standard API directly, with no Agents SDK or cloud service.

## Install

After the main Solo Studio installation:

1. Copy `Mix/worker.py`, `Mix/charts.py`, and `Mix/Connect OpenRouter.command` into
   `Scripts/Solo Studio/Mix/` in REAPER's resource folder.
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

Once ready, press Play and switch **Original** / **Candidate** while listening.
The song keeps playing from the same position; keys **1** and **2** select Original
and Candidate in the Mix tab. Keep and Revert also work during playback. Recording
locks these controls, and **Give feedback…** still requires stopped transport.
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

Closing the panel normally cancels and reverts an unfinished mix when its project
is active and stopped. Otherwise the local journal remains for recovery. Return
to the original project and reopen Mix. A completed candidate resumes review;
an interrupted pass must be reverted. A second project cannot start a
new session while the first has an unresolved journal. Keep/revert does not save
the song automatically; use your normal REAPER save workflow.

## Tools and limits

- Project inspection includes track GUIDs, names, levels, pan, mute/solo, parents,
  sends, regions, existing FX names and a filtered installed-plugin inventory.
- Volume is bounded to -60…+6 dB and at most +6 dB over the original. Pan supports
  classic/balance modes; dual/stereo pan and existing volume/pan automation are
  protected. Separate trim automation can ride a track without replacing its
  existing volume envelope.
- ReaEQ frequency/gain and ReaComp threshold/ratio/attack/release have physical-unit
  adapters with parameter-layout and formatted-readback validation.
- New instances of ReaEQ, ReaComp, FabFilter and UADx VST/VST3 effects are available.
  Existing FX are read-only. Parameters are inspected in pages of 96 with actual
  names/ranges/normalized values/formatted readbacks. Each normalized move is
  limited to 0.20. The agent must establish the mapping before using it.
- Third-party discovery is not a license/load test or a calibrated hardware
  emulation adapter. UAD DSP-only plugins, arbitrary FX, sends/routing edits,
  item edits and master FX changes are outside this version's tools.
- Full-mix and solo-in-place contribution renders run through routing and master
  processing. Solo measurements include shared returns; they are not dry stems.
- Analysis includes integrated LUFS, true peak, LRA, RMS, crest, spectrum,
  mid/side energy, correlation and one-second level envelopes. Graphs and complete
  measurements are saved in the local session folder. There is no real-time RTA
  or model audio listening in this version.
- Reference spectra are normalized energy distributions, not perceptual
  equal-loudness curves. Reference loudness is a target, subject to the -1 dBTP
  output ceiling, musical dynamics and available controls; reference peaks above
  that ceiling are not copied. Mastering tools are still outside this version.
- 24-bit render output makes clipping a failed candidate rather than preserving
  above-full-scale samples. A final true peak above -1 dBTP prevents Keep.
- Edits/transport changes stop tool execution. Tool schemas, finite bounds and
  plugin ownership are enforced in code; model instructions alone do not enforce
  these rules. Requests have timeouts and round/tool/render limits.

OpenRouter receives track names/settings, selected reference metrics, user mix
direction/feedback, tool results and decision messages. Audio, source file paths,
credentials and full project files are not submitted. Provider routing requests
`data_collection: deny` and parameter support; this is not a promise of zero data
retention. Choose a provider/model consistent with your own privacy requirements.
Only short model explanations and actual tool progress are shown, not private
reasoning tokens. No candidate quality or professional result is guaranteed by a
spectrum match.

## Validation

`python3 -m unittest discover -s Mix -p 'test_*.py' -v` tests protocol, typed
arguments, cancellation, local credentials, profile minimization, final metering
and failure paths. `Tests/Run mix checks.lua` uses an isolated REAPER tab and a
synthetic sine, with all hardware outputs removed. It checks real native effects,
automation, fader/pan edits, render setting restoration, A/B, rollback, manual-edit
preservation and recovery. It then runs `test_native_worker.py` through the real
file bridge and analyzer with a scripted model response and **no network call**.
The fixture is generated with:

```
ffmpeg -f lavfi -i 'sine=frequency=1000:duration=8:sample_rate=48000' -ac 2 Tests/mix-tone.wav
```

Live paid-model behavior requires the user's OpenRouter key and is a separate
validation from these deterministic tests.

On the development machine, 22 native integration checks passed, including the
complete asynchronous worker/REAPER/render/analyzer/chart loop. Seven Python
protocol tests and 47 existing recording UI/section tests also passed. During
testing, REAPER 7.55 hit a macOS accessibility crash when the Actions window was
closed by an accessibility press on Run/close. Running the test with **Run** and
leaving Actions open avoided that interaction. No production mixer call uses the
Actions window.
