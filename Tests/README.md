# Recording workflow checks

`Run master processor checks.lua` checks installed native UADx Ampex/SSL G and
StandardCLIP in a silent disposable project: factory tape settings, physical
gain/dynamics readbacks, UAD parameter pagination, host oversampling, failed-write
rollback, checkpoints, Original/Candidate, automation protection and Revert.
Close Solo Studio and stop transport first. It needs the installed licensed
plugins, UA's local Clean Ultralinear Master factory asset, and `mix-tone.wav`.
It restores the original project and verifies its audio fingerprint; results
are private in `master-processor-checks.txt`. It makes no paid/model calls.
`lua "$PWD/Tests/Master processor state.lua"` tests parameter pagination and
StandardCLIP's narrowly recognized restore metadata using synthetic fixtures;
gain, oversampling, bypass and unknown-format differences must still fail.

`Run advanced mix checks.lua` tests master gain, effect order, shared sends/buses,
pre-FX rides, named checkpoint restores, A/B, Revert and deferred gain-reduction
sampling in a silent disposable project. Close Solo Studio and stop transport
first; install Mix trim.jsfx and generate `mix-tone.wav` with `make_fixtures.py`.
The test restores the original song, verifies its audio fingerprint, and reopens
Solo Studio. It also checks cancelled/failed measurements and interrupted meter
recovery. Run `python3 Mix/test_native_advanced.py 'Tests/Advanced mix data/ID'`
on the reported data folder to verify actual float-WAV gain differences and GR.
`Mix/test_experiments.py` checks matched comparison outputs, chart delivery,
cancellation/failure restoration, retained recovery snapshots, and batch edits.

Ableton XML and native import checks are documented in the
[importer guide](../Ableton/README.md#installation-and-validation). They cover
source preservation, complete indexing, ambiguous relinks, tempo maps, loops,
trimmed/warped audio, AU/VST3 state, routing, automation and fixed lanes.

The standalone interaction checks need Lua 5.3 or newer. From the repository root:

```sh
lua "$PWD/Tests/Visual timeline interactions.lua"
lua "$PWD/Tests/Track management.lua"
lua "$PWD/Tests/Track meters.lua"
lua "$PWD/Tests/Take deletion.lua"
lua "$PWD/Tests/Take selection.lua"
lua "$PWD/Tests/Recorded tempo.lua"
lua "$PWD/Tests/Comp edges.lua"
lua "$PWD/Tests/Section recording handles.lua"
lua "$PWD/Tests/Panel tempo interactions.lua"
lua 'Tests/Section stop helper.lua'
lua 'Tests/Lead-in restoration.lua'
lua "$PWD/Tests/Mix comparison.lua"
lua "$PWD/Tests/Mix review controls.lua"
lua "$PWD/Tests/Mix window guard.lua"
lua "$PWD/Tests/Mix FX snapshots.lua"
```

`Track meters.lua` checks stereo group maxima, shared per-frame sampling, peak
hold/decay, overload clearing, project and membership changes, and invalid native
readings. The meter reader exposes no project writes or monitoring changes.

`Mix FX snapshots.lua` checks per-plugin snapshot boundaries, untouched adjacent
plugins, strict opaque-state comparisons and rollback after failed restoration.
`Run existing FX checks.lua` copies an existing master Pro-L 2 into a separate
project with no hardware outputs. It checks existing-plugin inspection, loading,
parameter changes, live Original/Candidate, recovery, automation overrides and
Revert, including preservation of later manual edits. Close Solo Studio and stop
all transport first; the current project must contain Pro-L 2. It restores the
original tab and reopens the panel, checks the original song's audio state, and
writes `existing-fx-native-checks.txt`. It makes no model requests.
It also reproduces bypassing an already offline Pro-L 2, combined offline/bypass
requests, and restoring those flags through Original/Candidate.

For the native REAPER checks, first generate their synthetic audio:

```sh
python3 Tests/make_fixtures.py
```

Install the production scripts as described in the main README. Stop transport,
then load the desired `Run ... checks.lua` script from REAPER's Actions list.
The integration, tempo, section, and lead-in checks use separate test projects;
the visual section check opens its own interactive fixture. Test projects, audio,
and logs are generated locally and excluded from Git.

`Mix window guard.lua` checks presentation-only changes, preserved render caches,
plugin/route/media/envelope/master edits, project timing, recovery and transport
locks. `Run mix window checks.lua` checks floating and chain windows on the active
stopped project's online Bass ReaEQ, without rendering, model requests or audio
setting edits. It restores window visibility and writes private diagnostics under
`Tests/Mix window check data/` and `mix-window-native-checks.txt`.

`Run lead-in checks.lua` requires an available audio device and native pre-roll
set to two measures. It records silent track outputs with muted hardware sends,
meters a generated guide tone, and checks punch-in, looping, and early stopping.
It restores the original project and verifies its track count, media count,
tempo, region count, and record arming.

The tuner has its own [DSP validation workbench](../Tuner/Tests/README.md).

`Desktop launcher.lua` checks opening the installed panel action, reusing an
existing panel, and missing-installation errors. `Panel tempo interactions.lua`
also verifies that raising the window preserves the active mix worker and that
closing the panel clears its nonpersistent launcher marker.
The same panel checks cover the Track settings dialog: input assignment, arming,
mixed monitoring, recording/AI locks, stale recording sets, and isolation from
background clicks, keyboard shortcuts, and timeline gestures.

`Run mix playback checks.lua` tests repeated Original/Candidate switches, Keep,
and Revert during real playback in a separate project with no hardware sends.
Generate `Tests/mix-tone.wav` using the command in the [mixing checks](../Mix/README.md#validation)
first. It requires a working audio device, writes `Tests/mix-playback-checks.txt`,
and checks that the user's original project remains unchanged. Run it with
**Run**, leaving Actions open (see the mixing README for the macOS accessibility caveat).

`Mix project sessions.lua` checks recovery from real local journals across saved
songs and unsaved tabs, legacy-pointer migration, completed sessions, stale edits,
and incomplete unrelated journals. `Mix review controls.lua` verifies that another
song's pending mix leaves setup available and Keep/Revert does not clear that song's
legacy recovery pointer. `Panel tempo interactions.lua` also checks that changing
the native project releases the old mix view before the next one is opened.

The timeline checks cover aligned take clips, gaps, partial passes, selection without auditioning, scrolling, and instrument changes. Panel checks exercise selecting, auditioning, and deleting from the list, plus selecting the new pass after Stop. `Take deletion.lua` tests synchronized deletion, stale selection protection, recording locks, and rollback after a partial failure. The native visual fixture also runs `Native take lanes.lua` with nine synthetic microphone tracks, checks single-step Undo and comp preservation, then opens the timeline for inspection.

Multiple-selection checks cover Cmd toggles, Shift ranges across offscreen rows, changing scope, neighboring selection after deletion, and preserving selection on failure. Batch deletion checks verify all take identities before mutation, rollback the whole batch on failure, and native nine-microphone deletion/Undo in one step.

`Native comp preview.lua` runs inside the visual fixture. It checks nine-microphone passage previews, source and comp preservation, fresh item identities, cleanup/recovery, rollback after a failed copy, committing during playback, and Undo without resurrecting temporary lanes. The runner also checks deferred preview lifetime and Stop cleanup. Its log reports when the audio device does not advance the playhead; transport-state assertions alone do not verify audible switching. These legacy preview checks remain as recovery regressions. The current panel uses direct native lane playback instead.

`Recorded tempo.lua` checks captured vs current BPM, microphone scope, loop passes, independent Stop handling, consecutive takes, unknown/mixed data, tempo maps, mid-recording tempo changes, stale jobs, and the actual Record/Stop integration. `Native recorded tempo.lua` runs in the visual fixture to check clip metadata on nine microphones, manual labelling/Undo, comp and split inheritance, and native project serialization. These native fixtures create silent items and do not capture live microphone input.

`Native comp playback toggle.lua` verifies direct Comp / Take playback on nine microphones, partial/split takes, no transport restart or cursor jump, unchanged item chunks and tempo labels, Stop persistence, and one-step Undo of deletion plus neighbor playback. Panel and timeline checks cover the toggle placement, automatic playback on single selection in Take mode, unchanged playback in Comp mode, multiselection, keyboard browsing, recording locks, and Use in comp passage bounds.

`Comp edges.lua` checks shared and outer edge edits, physical source limits, the least available microphone, stale drag protection, recording locks, and whole-set rollback. `Section recording handles.lua` checks musical bounds through tempo changes, temporary setting restoration (including closed projects), and per-pass limits in shared loop WAVs. Timeline gestures verify unsnapped edge movement, clamping, cancellation, and independence from song regions.

The visual runner also runs `Native comp edges.lua` and `Native section handles.lua`. The latter records silent track outputs in its disposable project and takes about 30 seconds with a working output device; it never records hardware inputs. It verifies real media offsets and lengths, single-pass and repeated loop capture, default visible trimming, per-pass handle metadata, and restoration of pre-roll/link preferences. The panel opens only after those checks finish.

`Track management.lua` exercises the real core, manager, and grouped Tracks view with a synthetic project: group expansion, linked volume ratios, mute restoration (including overlapping groups), group names stored in native track metadata, failed-write rollback, automation protection, AI/recording locks, stale edits, folder descendants and closing depths, surviving microphone membership, restored GUIDs, and cancelled deletion. Panel checks cover the tab, scrolling, sliders, and project reset. The boundary zoom interaction checks cover musical bar ranges, tempo/meter changes, double-clicks, pointer-centered zoom, returning to the previous view, and precise drags after zooming.

`Run boundary history checks.lua` verifies native boundary Undo/Redo across nine microphones during playback, plus track rename/deletion Undo and restored set membership. It opens a disposable panel; closing it restores the original project and checks every original track state chunk for exact preservation. Panel tests cover history buttons, keyboard shortcuts, empty history, recording locks, and drag cancellation; timeline tests verify that history refresh keeps the zoom and clears stale item hits.

`Run track group checks.lua` verifies native linked faders, linked pan (including
dual-pan endpoints and edge limits), group names, preserved member mute states,
Undo/Redo (including live volume/pan drags across deferred frames and cancellation),
and saved group metadata in a silent disposable
project. Close Solo Studio and stop transport first. The runner restores the user
project, checks all original track chunks for exact preservation, writes
`Tests/track-group-checks.txt`, and reopens Solo Studio's Tracks view. It never
records input or changes the original song's mix.

`Bounce library controls.lua` checks saved-version selection, instrumental
playback, Space/Pause/Resume behavior, and transport/AI/archiving locks.
`Run bounce checks.lua` renders synthetic guitar and vocal tracks in disposable
project copies, packages both WAV/M4A variants, resolves archived source files,
reopens a snapshot as an unsaved copy, and checks cancellation plus exact
preservation of the user's project. Generate its tones with `make_fixtures.py`.
See [bounce archive checks](../Bounces/README.md#checks) for Python validation.

`Project library.lua` checks discovery, persistent catalogs, explicit imports,
missing files, recording/AI locks, stale dialogs, and reuse of open project tabs.
It also verifies rename persistence, failed-write rollback, untouched project
files and unsaved edits, and renamed bounce titles with stable archive identity.
Panel checks cover Projects navigation, recording shortcut isolation, and mix
view reset when the active song changes. `Run project library checks.lua` creates
an isolated full-band song, verifies all X32 inputs and recording sets, switches
between dirty and unsaved projects, rejects duplicate names, reopens the saved
song, and verifies exact preservation of the user's original project. It never
records hardware inputs; fixtures and its catalog stay under `Tests/`.

The panel interaction checks also exercise the shared tempo, click-volume and
sound controls across Timeline, Takes, Tracks, Mix and Projects, including
view-switch drag cancellation and the active-AI tempo lock.
