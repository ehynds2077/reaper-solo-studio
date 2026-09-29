# Solo Studio for REAPER

A focused recording and take-review workspace for one person recording vocals, guitar, bass, or several drum microphones. Built for REAPER 7.55 using its native Lua tools. No additional plug-ins are required.

## Install from this repository

Developed and tested on REAPER 7.55 for macOS (Apple Silicon). The interface uses
native Lua/gfx and the tuner uses JSFX; other platforms have not been verified.

1. Download or clone this repository. In REAPER, choose **Options → Show REAPER resource path in explorer/finder**.
2. Copy the contents of `Scripts/` into `Scripts/Solo Studio/` under that resource folder. Keep all the Lua files together.
3. Copy `Effects/Solo Studio Strobe.jsfx` into `Effects/Solo Studio/` under the same resource folder.
4. Copy the four files in `Templates/` into `ProjectTemplates/`. These are empty project templates, with no recordings.
5. In **Actions → Show action list → New action → Load ReaScript**, load the installed `Solo Studio - Open recording panel.lua`. Run it, and assign **Cmd+Option+Shift+P** if that shortcut is free. Other `Solo Studio - ...` actions can be loaded and assigned shortcuts the same way.
6. Open **Projects → New song** to name and save a full-band X32 song. Select your audio device and check inputs. Other supplied templates are also available through REAPER’s File menu. In **Count-in...**, enable **Pre-roll before recording**, set **Pre-roll measures** to **2**, enable **Start pre-roll at start of measure**, and disable **Count-in before recording**.

The X32 template contains the channel assignments documented below. The other
templates leave inputs unassigned. REAPER input monitoring defaults to off for
use with interface monitoring; enable it if your setup requires software monitoring.

This repository contains source, empty templates, documentation, and test code.
Songs, recordings, settings backups, generated test audio, and local reports are
excluded by `.gitignore`. Synthetic test audio can be regenerated; see
[recording tests](Tests/README.md) and [tuner tests](Tuner/Tests/README.md).

The root-level `Build and install in REAPER.lua`, `Configure X32 recording.lua`,
and `Prepare scratch guitar and vocal.lua` scripts document the original setup
and template-building work. They are maintenance scripts for that local starter
project, not required installation steps. Use the supplied templates for new songs.

## Open the workspace

Press **Cmd+Option+Shift+P** from REAPER's arrangement to open the panel. Or, in **Actions → Show action list**, search **Solo Studio**, then run **Solo Studio - Open recording panel**. The other Solo Studio actions can also be assigned to keyboard shortcuts or MIDI controller buttons through this action list. On the original setup this shortcut is already assigned; new installations assign it during the steps above.

On macOS, installed scripts live in `~/Library/Application Support/REAPER/Scripts/Solo Studio`. This repository holds their editable source, templates, and checks. Original settings backups remain local and are not included here.

## Projects and new songs

Click **Projects** at the top of Solo Studio, or press **P**, to browse your songs.
Select a row and **Open song** (or Enter). An already-open song is selected in its
existing REAPER tab; a closed song opens in a new tab. Previous songs stay open,
including unsaved edits. Normal playback stops when switching; recording and
an active AI mix pass must finish first. Save changes before closing REAPER.

**New song** asks for a name and tempo, then saves an empty 15-track X32 full-band
project under `~/Desktop/Solo Studio Songs/<name>/<name>.RPP`, with recordings in
its `Media` folder. Scratch vocal (input 9) and scratch guitar (input 15) are
selected and armed. The final vocal, electric/acoustic guitar, bass, and nine-mic
drum sets are ready to select; acoustic guitar and bass still need input choices.
Software input monitoring is off for interface monitoring. Names already in use
are rejected rather than overwritten. The standalone **Create song project**
action uses this same flow. It requires the supplied **Ethan X32** template.

The list finds Solo Studio songs from open tabs, REAPER’s recent-project list,
and the default song folder (up to five subfolder levels). **Add existing…**
adds any saved `.RPP` without moving it. **Find a song…** filters the list;
**Refresh** rescans it. Select a saved song and click **Rename…** (or press **F2**)
to change its name in Solo Studio. Renames persist in the local catalog and are
used for future bounce filenames; existing project files, folders, recordings,
and archived mixes stay in place. Save an unnamed project once before renaming.
The list shows open/current status, unsaved edits, tempo,
track count, and last opened date. Missing files remain listed. Templates,
development fixtures, and archived bounce copies are excluded from automatic
discovery. The local catalog is saved in `Solo Studio/projects.json` inside
REAPER’s resource directory; neither the catalog nor your songs go to GitHub.

## Mix with AI

Open **Mix → Mix with AI** to connect OpenRouter, choose saved reference analyses,
and create a reversible candidate mix. The local worker can adjust track levels
and pan, add EQ/compression, write separate trim automation, render through
REAPER, and compare measured loudness, spectrum, dynamics and stereo balance.
Chat and progress appear after starting; **Give feedback…** refines the candidate.
Switch **Original / Candidate** while the song plays (keys **1 / 2** in Mix),
then **Keep mix** or **Revert**. Closing the panel preserves the unfinished pass.
If tracks, levels, or effects changed since the last pass, **Start a new mix**
opens setup using your current sound and preserves your manual edits. The old
snapshots and analysis stay on disk; **Revert previous pass** is also available.
Audio stays local;
project metadata and measured profiles go to the chosen OpenRouter provider.

AI mixing has a separate Python/FFmpeg setup and requires an OpenRouter key.
See [Mix installation, workflow, safeguards and limitations](Mix/README.md).
Existing recording, comping and tuner tools work without the mixing worker.

## Bounce and compare saved mixes

Open **Mix → Bounces → Bounce mix + instrumental**, name the version, and add
optional notes. Full song is the default; **Range** switches to the time selection.
Use **Vocal tracks…** to choose everything the instrumental should leave out.
Every version saves both WAVs, named M4As for texting to your phone, and full and
instrumental REAPER session copies in **Desktop/Solo Studio Mixes**.

Play previous versions directly from the list with **Play full / Instrumental**
and **Pause / Stop**. **Show files** reveals the files to share. **Open session
copy** opens the archived mix in a new REAPER tab. Source recordings are preserved
in the library's shared `_Media` folder; keep the whole library together when
moving it. Audition uses the Mac audio output.

Install `Bounces/library.py` in `Scripts/Solo Studio/Bounces/` and have FFmpeg
available. See [bounce workflow and archive details](Bounces/README.md).
[Lyric Helper API integration](Bounces/LYRIC_HELPER_V2.md) is planned for v2;
desktop exports do not upload anything.

## A recording session

1. Start from **File → Project templates → Solo Studio - One person band**, **One instrument**, or **Drums**. Save the project into its own folder before recording. New audio goes into `Media` within that folder.
2. Open Solo Studio. Choose the instrument's recording set. For an existing project, select the instrument track or all microphone tracks, then click **Use selected tracks**. Select the microphone tracks themselves, leaving their folder unselected.
3. Connect your interface and select it under **REAPER → Settings → Audio → Device**. Click **Inputs...** in Solo Studio to map one mono input per track. Use ordinary REAPER input controls for stereo sources. The templates have inputs unassigned until you do this.
4. Set the song tempo. Your setup uses a **two-bar musical lead-in before recording**; open **Count-in...** to adjust the native pre-roll settings. The click is enabled. **Arm set** arms only that instrument's tracks. Software monitoring starts off; enable it with headphones if you need to hear through REAPER, or use your interface's direct monitoring.
5. Click **Record**. Click **Stop & keep** to finish without deleting the pass. **Another take** stops and retains the current pass, returns to the selected passage's beginning, and records again. It uses the chosen song section, Full song, or a manual time selection.
6. For repeated passes, place the edit cursor at the section, click **4 bars** or **8 bars**, then record with Repeat enabled. Each pass goes to a fixed lane. **Clear selection** clears the time selection and loop range; it is disabled during recording. **Punch on** limits the recorded item to the selected passage while allowing playback around it; **Punch off** restores normal recording.

### Visual song timeline

Open **Timeline** at the upper right of Solo Studio. The horizontal ruler shows bars; colored blocks are song sections. The gold line is the cursor/playhead. **Takes** returns to take review, tempo, and metronome controls; **Mix** opens the mixing workspace.

- **Create visually:** drag across empty timeline space from the desired start to the desired end. A preview shows the bounds and duration. Releasing creates and selects the section; click its name below to rename it.
- **Create with an exact length:** click **New section...**, enter a name, start bar, and length in bars. Example: `Verse`, start `9`, length `8` ends at bar `17`.
- **Adjust:** drag either edge to resize, or drag the center to move a section. A shared edge adjusts both touching sections. Overlapping moves and boundaries that would erase a neighboring section are rejected. Audio stays in place.
- **Set exact bounds:** select a block and click **Start**, **End**, or **Length** below it. Start/end accept a whole bar or `bar.beat.hundredths`, such as `9.2.00`. Length accepts whole bars. The end is exclusive: start 1, end 9 is 8 bars.
- **Edit a boundary close up:** select a section or take passage and click **Zoom start** or **Zoom end**. The view shows one musical bar on each side, with individual beats and finer ruler ticks as you zoom further. You can also double-click a white Comp edge or a song-section edge to focus that exact boundary. Drag the white **Comp** edge to adjust the audio join across every microphone; comp edges use free timing. **Back** or **Escape** restores your previous wider view. Escape cancels a pending drag first.
- **Navigate:** click the ruler to position the cursor. Use **+ / -** to zoom further around the focused boundary, or **Option/Alt + mouse wheel** over the ruler or clips to zoom at the pointer. Use **< / >** or the mouse wheel over the timeline to pan, and **Fit song** to see the arrangement. **Snap: bars** aligns song-section edits to bars; switch it off for precise section times. Zooming leaves playback and your audio unchanged.

The selected recording set’s takes appear in lanes directly under the sections, on the same ruler. One lane represents one performance across the set’s microphones. Clips show their actual position and length, including partial takes and gaps; changing the selected section does not hide other takes. The ranges come from the first track in the set, so keep microphone lanes aligned. A growing red pass shows recording progress, and the kept take is selected after Stop.

The pinned green **Comp** row shows the passages you have kept. Source takes stay below it. Click a source clip to select its portion inside the song section under the mouse; outside a section, the whole clip is selected. The gold outline and passage bounds show exactly what will be used. Clicking a take's name instead uses the selected recording section or manual time selection, falling back to the whole take.

Use the **Comp | Take** toggle under the Comp title to choose what you hear. **Comp** plays your saved choices while you browse; **Take** plays the highlighted source lane across every microphone. In Take mode, clicking another take or pressing **Left / Right** switches playback immediately. It plays that whole take, including its actual gaps. The same controls appear in **Takes** view. Before a comp exists, only Take is available.

Switching keeps a running song at its current position. When stopped, it prepares the chosen lane without starting transport; press **Space** or **Play** to listen. Stopping or closing the panel leaves that lane selected for playback. No temporary audio copies are created. **Use in comp** copies the selected passage into the comp and returns to Comp mode; later choices replace only their selected range. The source recordings stay intact. Clicking a saved clip in the Comp row also returns to Comp. Use REAPER's native lane controls for detailed crossfades.

**Undo / Redo** at the top of the panel use the project's normal REAPER history. Each released Comp-boundary drag is one step across every microphone, and Undo keeps your boundary close-up in place. The label beneath Undo shows the next edit it will reverse. **Cmd/Ctrl+Z** works with the panel focused; **Shift+Cmd/Ctrl+Z** or **Cmd/Ctrl+Y** redoes. Undo during an unfinished drag first cancels that preview. History controls are disabled during recording and while the AI is applying a mix.

**Cmd-click** (Ctrl-click on Windows) toggles individual takes; **Shift-click** selects a range, including takes reached by scrolling. Cmd-Shift-click adds a range. Selected takes are highlighted in both Timeline and Takes. **Favorite**, **Take note**, and **Rename** remain available. Use the mouse wheel over source lanes or **Up / Down** to browse. Zoom and pan apply to sections and clips together. Take playback requires an aligned source lane on every microphone. Comping additionally requires audio coverage of the selected passage; clicking a partial clip uses its actual bounds.

**Delete take** in either Timeline or Takes removes the entire selected lane’s audio items across the recording set, including parts outside the selected section. With multiple takes selected, the button shows **Delete N takes** and removes the whole batch in one Undo step. Take playback, note, rename, favorite, and comp actions require a single selected take. Adding to a multiselection leaves playback unchanged; Comp remains available. After deletion, selection moves to the next surviving take next to the focused take, or the previous one if there is no next take; it stays empty if no takes remain. In Take mode the surviving neighbor also becomes the playback lane, within the same Undo step; Comp mode keeps the saved comp playing. Source audio files stay on disk. **Cmd+Z in REAPER’s arrangement** restores the whole operation, including notes and favorites. Separate comp copies stay intact when their source take is removed. Empty native lanes remain in REAPER to preserve microphone and comp alignment, but disappear from Solo Studio’s take list. If every source take is deleted, choose Comp to return to any saved passages. Deletion is disabled during recording.

### Manage project tracks

Open **Tracks** beside Timeline, Takes, and Mix to see every project track, its folder indentation, recording set, input, item count, and effect count. Click a row to select that track in REAPER. Use **+ Instrument** to add another guitar, vocal, or other recording part; each addition can have its own name and recording set.

- **Rename...** changes the native track name. A single-track recording set follows that name, so doubled guitars or backing vocals are easy to distinguish in the recording-set menu. Multitrack set names stay separate from microphone names.
- **Delete...** shows a confirmation with the number of items and effects being removed. Deleting a folder includes its child tracks and states that explicitly. Source audio files remain on disk. **Cmd+Z in REAPER** restores the operation, including recordings, effects, and folder structure.
- Deleting one microphone leaves the surviving tracks available in their recording set. Empty sets disappear from the menu; native Undo restores their membership. Renaming and deleting are disabled while recording.

### Build a song from your scratch take

1. Choose **Scratch guitar + vocal**, then **Full song**. Record the guide and use **Stop & keep** when finished.
2. In **Takes & click**, choose the scratch take you want. Open **Song timeline** and choose **Use scratch take** to create a Song block covering the playing guide.
3. Click the ruler at each transition, then **Split at cursor (B)**. You can also press **B** with the panel focused while listening. Select the resulting blocks and click their names to rename them Intro, Verse, Chorus, etc. Drag shared edges to refine the transitions.
4. Click a section, choose Drums, guitar, vocals, or another recording set, then **Record section**. The section stays selected when changing instruments. **One pass** records through two bars after the section; **Loop takes** repeats the section plus its two-bar handles until **Stop & keep**. The two bars leading into the section play at 6 dB below normal alongside the click, then playback returns to normal volume when the section starts.
5. Stay in **Timeline**, switch to **Take** and click through the section's takes, and **Use in comp** to add the chosen performance to the comp. Repeat for other sections. All microphones in the recording set switch and comp together.

You can instead build your arrangement directly by drawing separate blocks or using **New section...**; a scratch outline is optional. **Full song** returns to complete takes from the beginning. **Another take** repeats the chosen section or starts another full-song pass. Manual passage controls and **Clear selection** release the named-section target.

Sections save as ordinary REAPER regions and also appear in its arrangement. Mapping, moving, resizing, or removing a label never moves, splits, or deletes recorded audio. Region edits can be undone from REAPER with Cmd+Z. Save the project after mapping the structure.

### Recording handles and musical lead-in

**Record section** captures two musical bars before the section and two bars after it. REAPER's native time-selection punch keeps the visible clip trimmed to the section; the WAV retains the extra audio. Keep playing through **Recording tail...** until the automatic stop. **Another take** does the same. **Loop takes** includes the lead-in and tail on every pass, with saved handle limits preventing an edit from reaching into a different pass in the same WAV. Full-song and manual recording retain their existing behavior.

The lead-in plays your existing mix 6 dB quieter alongside the click, then returns to normal level at the section start. This repeats on each loop. Capture starts explicitly at the lead-in, so there is no additional native pre-roll waiting period. At the start of the song, where there is no earlier timeline audio, the native two-bar click lead-in remains. Sections within the first two bars get only the preceding timeline audio available; earlier material is never invented. A manual early stop keeps only the audio actually captured.

Leave **Count-in before recording** off in **Click sound... / Count-in...**. Keep **Pre-roll measures: 2** for the song-start count-in. Solo Studio temporarily adjusts native pre-roll and the loop/time-selection link for section recording, and restores them on Stop, including native Stop and closing the recording project. The independent helper continues when the panel closes.

Playback dimming affects hardware outputs. Track faders, recorded input gain, click volume, and X32 direct monitoring remain unchanged. Intentional output gain or routing changes during the lead-in are preserved.

### Adjusting comp joins

After **Use in comp**, drag a vertical edge handle on the green **Comp** row. A shared edge rolls the handoff: dragging right reveals more of the first performance; dragging left reveals more of the second. Outer edges can reveal a lead-in or tail. The gold guide shows the range available across every microphone. Comp-edge dragging does not snap to bars; use **+** to zoom for drum-hit adjustments.

The drag previews locally and commits on release, with one Undo step across the recording set. **Escape** cancels a drag. Running playback continues. Source takes and the Verse/Chorus section labels stay in place, and existing overlaps are preserved. Use native REAPER controls for detailed fade shaping. The same planning/editing operations are exposed through `M.comp_edges().list()`, `.plan(key, position, signature)`, and `.move(key, position, signature)` for future automation.

Older recordings can expose any handles already present in their files; missing audio cannot be recovered. Available bounds also respect per-pass recording metadata, source length, and the shortest microphone capture. Looped/stretched sources that exceed their media bounds, MIDI, or clips with take automation require REAPER's native editor.

### Tempo and click controls

The shared header keeps **Tempo**, **Click volume**, **Click on/off**, and
**Click sound…** visible in Timeline, Takes, Tracks, Mix (including Bounces),
and Projects. These controls always apply to the current open song.

- Drag **Tempo** to choose 20–300 BPM, or click the BPM value to type an exact tempo (including decimals). Slider changes apply when you release the mouse. Tempo changes are locked during recording and an active AI mix; songs with tempo markers use REAPER's tempo-map editor.
- Drag **Click volume** from mute to 0 dB, or click the dB value to enter -60 to 0 dB. This changes REAPER's metronome volume and preserves the relative volume of accented beats. It does not change instrument gain or X32 monitoring.
- **Click sound...** opens REAPER's metronome settings. Choose the **Waveform shape**, change the A/B frequencies, or select **Sample** and browse to your own click audio. **Sample presets** saves combinations you want to reuse. **Count-in...** opens the same window at its count-in controls.
- Tempo, click volume, sound, and count-in are saved with the project. Opening Solo Studio does not reset them.

### Recorded tempo on takes

New recordings started through Solo Studio capture the song tempo before recording and attach it to every kept microphone clip. Full-song, section, Another take, and loop passes are covered, even if the panel closes before Stop. The label remains with the clip when you split it or copy it into a comp; changing the song tempo does not relabel old takes. These are project/item labels, not edits to the original WAV files. Capturing the label adds a **Solo Studio: store recorded tempo** entry to REAPER's Undo history; undoing that entry removes the label, while the recording remains.

Both **Timeline** and **Takes** display the recorded BPM. Gold **different** labels identify known fixed-tempo takes that differ from the current fixed song tempo. Open **Tempo... → Select takes with different tempo**, review the highlighted takes, then use **Delete N takes**. This uses the existing whole-take deletion and Undo behavior, across the recording set. In Takes view, selection applies to the currently filtered list; Timeline includes all source takes for the instrument. Comps and temporary previews are excluded.

Older recordings without captured metadata show **Tempo ?**. **Tempo... → Set recorded BPM for selected takes...** lets you supply a tempo you know; it changes labels only and supports multiple takes with one Undo. **Select takes with unknown tempo** helps find these recordings. Solo Studio does not infer their recording tempo from today's song tempo or analyze the audio to guess it. Recordings started directly in REAPER outside Solo Studio do not automatically get this label.

Tempo-map recordings retain their map and show **Tempo map**. If the project tempo changes during a recording, the label shows **Tempo changed**. Mixed, unknown, and mapped tempos are excluded from automatic mismatch selection; known BPM comparisons use a 0.005 BPM tolerance.

### Example X32 Producer setup

Use **File → Project templates → Solo Studio - Ethan X32** for a new song. The original local setup also has a configured **Starter song**, which is not distributed. Save each new song in its own folder. This personal template has a dedicated scratch vocal/guitar pair, nine drum mics, electric guitar, acoustic guitar, vocals, and bass.

Start with **Scratch guitar + vocal**, which arms **Scratch vocal on USB 9** and **Scratch guitar on USB 15** together. These two guide tracks are grouped for synchronized takes and comping. The template opens with only this pair armed and input monitoring off. After the guide performance, choose **Drums** and click **Arm set** or **Record**; the scratch tracks remain available for playback. Mute the scratch tracks when replacing them with final parts.

| Drum microphone | X32 USB input |
|---|---|
| Kick | 1 |
| Snare top | 2 |
| Snare bottom | 3 |
| Tom 1 | 4 |
| Tom 2 | 5 |
| Hi-hat | 6 |
| Overhead L | 7 |
| Overhead R | 8 |
| Ride | 11 |

The **Drums** recording set includes all nine microphones in one media-edit group with fixed lanes. The overheads are panned left/right. Select **Drums**, then **Arm set** or **Record**, to arm all nine drum tracks. The click and two-bar musical pre-roll are enabled; set the song tempo before recording.

Monitor live inputs through the X32. REAPER's track input monitoring is **off**, which still allows recording and input metering. These are computer USB input numbers; the X32's card routing must supply the corresponding microphones. Playback return routing is unchanged.

The final **Vocals** set uses USB **9**, and **Electric guitar** uses USB **15**. **Acoustic guitar** and **Bass** still need their input channels assigned. Choose a set from the blue **Recording set** menu, use **Inputs...** to assign or change its X32 USB input, then **Arm set** or **Record** to switch the armed tracks. If recording a guitar DI and an amp mic simultaneously, add both tracks to the same recording set.

The setup was checked inside REAPER: all nine drum input assignments, monitoring off, media-edit grouping, fixed lanes, and drum-only arming. No performance was recorded during setup; confirm microphone signals on the input meters before your first take. A copy of the starter before these changes is in `Backups/before-x32-recording`.

## Review and comp

- Choose **Take** under the Comp title, then click source clips or press **Left / Right** to compare takes. Choose **Comp** to hear your saved choices again. Switching preserves running playback; when stopped, use **Play** to listen.
- **Favorite**, **Take note**, and **Passage note** help preserve your decisions. Passage notes belong to the exact native time selection. Save the project to persist them.
- **Use in comp** copies the selected passage into REAPER's native comp lane on every microphone and activates it. The green Comp row shows kept passages; later choices replace only their range. The source recordings stay available.
- In REAPER's arrangement, use **Cmd+Z** to undo comp edits. Native lane controls remain available for detailed edits and crossfades.
- The tool checks matching lane counts and audio coverage, but it cannot infer whether manually imported microphone files are the same performance. Keep corresponding recording passes on corresponding lanes. If you reorder source lanes manually, reorder every microphone consistently.
- Keep the recording set's edit group intact. A set cannot be captured while excluding another track in its existing media edit group.

## Keyboard control

When the Solo Studio panel has focus:

| Key | Action |
|---|---|
| Space | Play / stop and keep recording |
| R | Record / stop and keep |
| N | Another take from the selected passage |
| Left / Right | Select previous / next take; Take mode also switches playback |
| F | Toggle favorite |
| B | Mark a song transition |
| Cmd/Ctrl+Z | Undo; an unfinished drag is cancelled first |
| Shift+Cmd/Ctrl+Z or Cmd/Ctrl+Y | Redo |
| Escape | Cancel an active drag, return from boundary close-up, or close the panel |

The corresponding independent actions work from the main REAPER window once you assign shortcuts. A MIDI footswitch can use the same actions. The **Tuner** button/action opens the custom **Solo Studio Strobe** on a silent helper track, using the selected instrument track's input or asking for its X32 USB input. See [the tuner guide](Tuner/README.md). Closing the tuner disarms its helper; instrument track monitoring stays unchanged.

## What this first version covers

Recording sets, a saved song-section map, full-song/section recording, repeat passes, synchronized auditioning, notes and favorites, section comping, and starter instrument templates. Automatic transient scoring and automatic take selection are future work. This is an initial custom tool, verified with synthetic recordings; real microphone recording and performance under your full plug-in workload still need a session with your interface.

## Undoing the setup

Remove the Solo Studio actions from REAPER's action list, then remove the `Scripts/Solo Studio` folder and the four `ProjectTemplates/Solo Studio - ...` files. Recordings and ordinary REAPER comps remain normal project media. Keep the scripts if you want to continue viewing their saved notes. The pre-setup settings copy is in this folder's `Backups` directory. Avoid restoring the entire old configuration over later REAPER changes unless you intend to discard those changes.

## Development

The [Reference Lab](ReferenceLab/README.md) is a separate local analysis workbench for comparing reference mixes. It saves measured loudness, tonal distribution, stereo metrics, and section profiles for reuse. It does not yet make AI mix changes. Reference audio, manifests, profiles, and generated reports remain outside Git.

`Scripts/solo_core.lua` contains the recording and comping operations; the panel and small action entry points call that module. `Scripts/solo_tempo.lua` controls native tempo and metronome settings. `Tests/Integration.lua` creates and saves an isolated test project using silent WAV audio, tests both microphone tracks and persistence, closes only that test tab, and restores the previous project. Results are written to `Tests/integration-results.txt`. `Tests/Run tempo checks.lua` checks the installed tempo module in an isolated project and verifies that the user's media, tempo, click volume, and record arming remain unchanged. `Tests/Panel tempo interactions.lua` runs outside REAPER with a fake drawing surface to check drag/release behavior and cancellation when recording starts or the project changes.

`Scripts/solo_sections.lua` manages native regions and recording scope. The independent `Solo Studio - Finish section recording.lua` helper follows a single recording even if the panel closes. `Tests/Run section checks.lua` checks regions, scratch bounds, multitrack comping, save/reopen, and isolated silent-output recording when the audio device is available. `Tests/Section stop helper.lua` checks endpoint timing, count-in, cancellation, project ownership, and replacement recordings without hardware. Section editing passed 22 native checks; the stop helper passed 11 simulated checks. With the X32 connected, the native musical lead-in check also verified automatic stopping and recorded item boundaries on two tracks.

`Scripts/solo_timeline.lua` provides the graphical section editor. `Tests/Visual timeline interactions.lua` checks drag preview/commit, resizing, movement, snapping, input parsing, and cancellation. `Tests/Run visual section checks.lua` verifies native musical positions, shared-edge updates, and single-step undo, then opens a disposable visual fixture. Closing that test panel saves/closes only its fixture and restores the user song.

`Scripts/solo_leadin.lua` temporarily dims hardware playback sends and journals their original levels for safe restoration. `Tests/Run lead-in checks.lua` passed 15 native checks with silent output recording: guide audio during pre-roll, 6 dB attenuation, restoration at punch-in and on native Stop, repeating takes, song-start pre-roll, and unchanged click settings; it also verified the user song and arming were preserved. `Tests/Lead-in restoration.lua` passed 10 simulated checks covering direct outputs, repeated takes, ownership, manual changes, and recovery.

The legacy `Scripts/solo_comp_preview.lua` journals temporary passage previews and restores prior lane playback. Native nine-microphone checks cover preserved source/comp audio, unique copy identities, exact passage bounds, rollback, recovery, transport continuity, commit during playback, and Undo. Playhead advancement is reported separately when an audio device is available.

`Tests/Native comp playback toggle.lua` checks direct Comp / Take switching on nine microphones, including partial lanes, running/stopped transport, unchanged media and tempo labels, and deletion with neighbor playback restored by one Undo. Panel checks cover automatic selection playback, multiselection, recording locks, and the removal of explicit Preview controls.

`Scripts/solo_recording_handles.lua` journals temporary capture settings and records per-pass source bounds. `Scripts/solo_comp_edges.lua` plans and applies synchronized comp-edge edits. Native tests cover nine-microphone edits/Undo during playback, unchanged source takes, retained handles in comp copies, and silent output recordings with trimmed clips plus two-bar media handles in single and loop modes. Physical microphone capture still needs an interface session.
