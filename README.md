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
6. Start a new song from a Solo Studio project template, save it in its own folder, select your audio device, and assign inputs. In **Count-in...**, enable **Pre-roll before recording**, set **Pre-roll measures** to **2**, enable **Start pre-roll at start of measure**, and disable **Count-in before recording**.

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

## Mix with AI

Open **Mix → Mix with AI** to connect OpenRouter, choose saved reference analyses,
and create a reversible candidate mix. The local worker can adjust track levels
and pan, add EQ/compression, write separate trim automation, render through
REAPER, and compare measured loudness, spectrum, dynamics and stereo balance.
Chat and progress appear after starting; **Give feedback…** refines the candidate.
Use **Original / Candidate**, then **Keep mix** or **Revert**. Audio stays local;
project metadata and measured profiles go to the chosen OpenRouter provider.

AI mixing has a separate Python/FFmpeg setup and requires an OpenRouter key.
See [Mix installation, workflow, safeguards and limitations](Mix/README.md).
Existing recording, comping and tuner tools work without the mixing worker.

## A recording session

1. Start from **File → Project templates → Solo Studio - One person band**, **One instrument**, or **Drums**. Save the project into its own folder before recording. New audio goes into `Media` within that folder.
2. Open Solo Studio. Choose the instrument's recording set. For an existing project, select the instrument track or all microphone tracks, then click **Use selected tracks**. Select the microphone tracks themselves, leaving their folder unselected.
3. Connect your interface and select it under **REAPER → Settings → Audio → Device**. Click **Inputs...** in Solo Studio to map one mono input per track. Use ordinary REAPER input controls for stereo sources. The templates have inputs unassigned until you do this.
4. Set the song tempo. Your setup uses a **two-bar musical lead-in before recording**; open **Count-in...** to adjust the native pre-roll settings. The click is enabled. **Arm set** arms only that instrument's tracks. Software monitoring starts off; enable it with headphones if you need to hear through REAPER, or use your interface's direct monitoring.
5. Click **Record**. Click **Stop & keep** to finish without deleting the pass. **Another take** stops and retains the current pass, returns to the selected passage's beginning, and records again. It uses the chosen song section, Full song, or a manual time selection.
6. For repeated passes, place the edit cursor at the section, click **4 bars** or **8 bars**, then record with Repeat enabled. Each pass goes to a fixed lane. **Clear selection** clears the time selection and loop range; it is disabled during recording. **Punch on** limits the recorded item to the selected passage while allowing playback around it; **Punch off** restores normal recording.

### Visual song timeline

Open **Song timeline** at the upper right of Solo Studio. The horizontal ruler shows bars; colored blocks are song sections. The gold line is the cursor/playhead. **Takes** returns to take review, tempo, and metronome controls; **Mix** opens the mixing workspace.

- **Create visually:** drag across empty timeline space from the desired start to the desired end. A preview shows the bounds and duration. Releasing creates and selects the section; click its name below to rename it.
- **Create with an exact length:** click **New section...**, enter a name, start bar, and length in bars. Example: `Verse`, start `9`, length `8` ends at bar `17`.
- **Adjust:** drag either edge to resize, or drag the center to move a section. A shared edge adjusts both touching sections. Overlapping moves and boundaries that would erase a neighboring section are rejected. Audio stays in place.
- **Set exact bounds:** select a block and click **Start**, **End**, or **Length** below it. Start/end accept a whole bar or `bar.beat.hundredths`, such as `9.2.00`. Length accepts whole bars. The end is exclusive: start 1, end 9 is 8 bars.
- **Navigate:** click the ruler to position the cursor. Use **+ / -** to zoom, **< / >** or the mouse wheel over the timeline to pan, and **Fit song** to see the arrangement. **Snap: bars** aligns dragged edits to bars; switch it off for precise times. **Escape** cancels an active drag.

### Build a song from your scratch take

1. Choose **Scratch guitar + vocal**, then **Full song**. Record the guide and use **Stop & keep** when finished.
2. In **Takes & click**, choose the scratch take you want. Open **Song timeline** and choose **Use scratch take** to create a Song block covering the playing guide.
3. Click the ruler at each transition, then **Split at cursor (B)**. You can also press **B** with the panel focused while listening. Select the resulting blocks and click their names to rename them Intro, Verse, Chorus, etc. Drag shared edges to refine the transitions.
4. Click a section, choose Drums, guitar, vocals, or another recording set, then **Record section**. The section stays selected when changing instruments. **One pass** stops and keeps the take at its end; **Loop takes** repeats until **Stop & keep**. The two bars leading into the section play at 6 dB below normal alongside the click, then playback returns to normal volume when the section starts.
5. Switch to **Takes & click**, compare the section's takes, and **Keep passage** to add the chosen performance to the comp. Repeat for other sections. All microphones in the recording set switch and comp together.

You can instead build your arrangement directly by drawing separate blocks or using **New section...**; a scratch outline is optional. **Full song** returns to complete takes from the beginning. **Another take** repeats the chosen section or starts another full-song pass. Manual passage controls and **Clear selection** release the named-section target.

Sections save as ordinary REAPER regions and also appear in its arrangement. Mapping, moving, resizing, or removing a label never moves, splits, or deletes recorded audio. Region edits can be undone from REAPER with Cmd+Z. Save the project after mapping the structure.

### Musical lead-in

**Record section** plays the preceding two bars of your existing mix, 6 dB quieter, with the metronome. It records into the selected section and restores normal playback volume at the punch-in. **Another take** gives you the same lead-in; **Loop takes** gives it once before the first pass. Stopping early also restores the original playback level. At bar one there is no preceding audio, so you hear two bars of click.

In **Count-in...**, use **Pre-roll before recording**, **Pre-roll measures: 2**, and **Start pre-roll at start of measure**. Leave **Count-in before recording** off: enabling both adds a separate click-only count-in before the musical lead-in. Pre-roll preferences belong to REAPER; click/count-in settings belong to each project. Older projects may still have the separate count-in enabled.

The temporary reduction affects REAPER's hardware playback outputs. Track faders, recorded input levels, native click settings, and your X32 direct monitoring stay as configured. If you manually change an output's gain or routing during the lead-in, Solo Studio preserves your new setting.

### Tempo and click controls

- Drag **Tempo** to choose 20–300 BPM, or click the BPM value to type an exact tempo (including decimals). Slider changes apply when you release the mouse. Tempo changes are locked during recording; songs with tempo markers use REAPER's tempo-map editor.
- Drag **Click volume** from mute to 0 dB, or click the dB value to enter -60 to 0 dB. This changes REAPER's metronome volume and preserves the relative volume of accented beats. It does not change instrument gain or X32 monitoring.
- **Click sound...** opens REAPER's metronome settings. Choose the **Waveform shape**, change the A/B frequencies, or select **Sample** and browse to your own click audio. **Sample presets** saves combinations you want to reuse. **Count-in...** opens the same window at its count-in controls.
- Tempo, click volume, sound, and count-in are saved with the project. Opening Solo Studio does not reset them.

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

- Click a take to audition its matching lanes across the complete recording set. Previous/Next also switch the complete set.
- **Favorite**, **Take note**, and **Passage note** help preserve your decisions. Passage notes belong to the exact selected time range. Save the project to persist them.
- **Keep passage** copies the selected time range into REAPER's native comp lane on every microphone. It requires playback to be stopped. Later selections add to that comp. Original source items are preserved.
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
| Left / Right | Previous / next take |
| F | Toggle favorite |
| B | Mark a song transition |
| Escape | Close the panel |

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
