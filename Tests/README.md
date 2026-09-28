# Recording workflow checks

The standalone interaction checks need Lua 5.3 or newer. From the repository root:

```sh
lua "$PWD/Tests/Visual timeline interactions.lua"
lua "$PWD/Tests/Take deletion.lua"
lua "$PWD/Tests/Take selection.lua"
lua "$PWD/Tests/Recorded tempo.lua"
lua "$PWD/Tests/Panel tempo interactions.lua"
lua 'Tests/Section stop helper.lua'
lua 'Tests/Lead-in restoration.lua'
lua "$PWD/Tests/Mix comparison.lua"
lua "$PWD/Tests/Mix review controls.lua"
```

For the native REAPER checks, first generate their synthetic audio:

```sh
python3 Tests/make_fixtures.py
```

Install the production scripts as described in the main README. Stop transport,
then load the desired `Run ... checks.lua` script from REAPER's Actions list.
The integration, tempo, section, and lead-in checks use separate test projects;
the visual section check opens its own interactive fixture. Test projects, audio,
and logs are generated locally and excluded from Git.

`Run lead-in checks.lua` requires an available audio device and native pre-roll
set to two measures. It records silent track outputs with muted hardware sends,
meters a generated guide tone, and checks punch-in, looping, and early stopping.
It restores the original project and verifies its track count, media count,
tempo, region count, and record arming.

The tuner has its own [DSP validation workbench](../Tuner/Tests/README.md).

`Run mix playback checks.lua` tests repeated Original/Candidate switches, Keep,
and Revert during real playback in a separate project with no hardware sends.
Generate `Tests/mix-tone.wav` using the command in the [mixing checks](../Mix/README.md#validation)
first. It requires a working audio device, writes `Tests/mix-playback-checks.txt`,
and checks that the user's original project remains unchanged. Run it with
**Run**, leaving Actions open (see the mixing README for the macOS accessibility caveat).

The timeline checks cover aligned take clips, gaps, partial passes, selection without auditioning, scrolling, and instrument changes. Panel checks exercise selecting, auditioning, and deleting from the list, plus selecting the new pass after Stop. `Take deletion.lua` tests synchronized deletion, stale selection protection, recording locks, and rollback after a partial failure. The native visual fixture also runs `Native take lanes.lua` with nine synthetic microphone tracks, checks single-step Undo and comp preservation, then opens the timeline for inspection.

Multiple-selection checks cover Cmd toggles, Shift ranges across offscreen rows, changing scope, neighboring selection after deletion, and preserving selection on failure. Batch deletion checks verify all take identities before mutation, rollback the whole batch on failure, and native nine-microphone deletion/Undo in one step.

`Native comp preview.lua` runs inside the visual fixture. It checks nine-microphone passage previews, source and comp preservation, fresh item identities, cleanup/recovery, rollback after a failed copy, committing during playback, and Undo without resurrecting temporary lanes. The runner also checks deferred preview lifetime and Stop cleanup. Its log reports when the audio device does not advance the playhead; transport-state assertions alone do not verify audible switching. Panel and timeline interaction checks cover clip/section bounds, the pinned Comp row, Use in comp, return to comp, and arrow-key comparisons.

`Recorded tempo.lua` checks captured vs current BPM, microphone scope, loop passes, independent Stop handling, consecutive takes, unknown/mixed data, tempo maps, mid-recording tempo changes, stale jobs, and the actual Record/Stop integration. `Native recorded tempo.lua` runs in the visual fixture to check clip metadata on nine microphones, manual labelling/Undo, comp and split inheritance, and native project serialization. These native fixtures create silent items and do not capture live microphone input.
