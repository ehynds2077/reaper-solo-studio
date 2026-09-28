# Solo Studio Strobe

A custom strobe tuner for guitar and bass, installed as **JS: Solo Studio Strobe** in REAPER. This is a native JSFX plugin; it does not require an installer, iLok, or an additional extension. It is not a VST/AU for other DAWs.

## Open it

1. Select your guitar or bass recording track.
2. Open Solo Studio with **Cmd+Option+Shift+P**, then click **Tuner**. Alternatively, run **Solo Studio - Tuner** from REAPER's action list.
3. If that track has no recording input assigned, enter the **X32 USB input number** carrying the instrument. This is the computer-facing card routing, which may differ from the console's physical input number. The tuner remembers its input separately and does not change the recording track.
4. Play one string at a time. Give the display about half a second to settle after the attack. Tighten a flat string; loosen a sharp one. Aim to stop the bands moving.

The launcher makes one reusable **Tuner - … (silent)** helper track. It listens without recording, has no parent/master or hardware sends, and also mutes the plugin output. Closing the floating tuner disarms that helper. Recording through Solo Studio or switching projects stops its listening session. Open Tuner again to restart it. Your instrument track's record arm, effects, and monitoring settings are preserved.

For the X32, continue monitoring through the mixer. The helper's software monitoring is enabled only to feed the tuner; it has no audible output. **Muted** in this plugin does not mute the X32's direct monitor sound.

You can also insert **Solo Studio Strobe** through the ordinary FX browser. A track FX instance needs incoming audio (record arm plus monitoring, or recorded media playback). Its default is transparent pass-through, with zero added audio latency. Use the Solo Studio launcher for the silent X32 workflow.

## Controls

- **Auto** follows the nearest chromatic note. **Lock** holds the current target.
- **Guitar / Drop D / Bass** changes the string buttons. Clicking a string locks its target. Return to Auto for other notes or tunings. Bass includes low B.
- **A4** is adjustable from 400 to 480 Hz with the minus/plus buttons, in 0.1 Hz steps. Click its value for 415, 432, 440 or 442 Hz presets.
- **Input** cycles left, right, and mono sum. Leave it on left for the launcher's mono input. Opposite-polarity stereo channels can cancel in sum mode.
- **Detail** cycles 1x, 4x and 16x display magnification. Higher values make small pitch differences easier to see without changing the target pitch.
- **Audio thru / Muted** controls only audio passing through this plugin.

The three bands follow the signal's fundamental, second harmonic and fourth harmonic against reference oscillators. Rightward motion means sharp; leftward means flat. Faint bands have insufficient energy at that harmonic. These are phase measurements, not a looping animation driven by a rounded number. Numeric cents use a separate periodicity estimate. Very faint/unstable signals clear the reading instead of retaining an old in-tune result.

## Scope and verification

Designed for one note at a time, approximately **30–1400 Hz** (low B on a five-string bass through high guitar notes). Equal temperament, with adjustable concert pitch. It does not include Peterson's proprietary sweeteners or claim equivalence to Peterson hardware/software. The cents display's two decimal places are display resolution, not a guaranteed accuracy specification.

An instrumented copy of the actual JSFX ran through REAPER's native renderer at **44.1, 48 and 96 kHz**. Tests include known offsets down to ±0.1 cent, sine waves, harmonic plucks, weak fundamentals, noise, silence, alternate input channels, and mute/pass-through. Maximum settled pitch error across these synthetic cases was **0.315 cents**. Strobe direction/rate and 442 Hz/manual target behavior were also checked. Audio at 48 kHz was bit-identical with the input in pass-through mode and exactly zero when muted. See `Tests/results.txt` and `Tests/measurements.json` for the measured results.

These tests do not establish accuracy on every real guitar, under bleed/distortion, or against an independently calibrated hardware clock. Use a clean DI or a clear microphone signal; real-instrument testing is the next useful check.

## Files and development

- Source: `../Effects/Solo Studio Strobe.jsfx`
- Installed effect: `~/Library/Application Support/REAPER/Effects/Solo Studio/Solo Studio Strobe.jsfx`
- Silent launcher: `../Scripts/solo_tuner.lua`
- Test generation: `Tests/make_fixtures.py`; native host harness: `Tests/Run tuner checks.lua`; analysis: `Tests/analyze_results.py`.
- Normalized autocorrelation follows the general approach described by McLeod and Wyvill in [A Smarter Way to Find Pitch](https://quod.lib.umich.edu/i/icmc/bbp2372.2005.107/1/--smarter-way-to-find-pitch?page=root%3Bsize%3D75%3Bview%3Dtext), with an original implementation and a multi-period refinement. Phase bands use quadrature reference oscillators with low-pass filtering. [REAPER JSFX reference](https://www.reaper.fm/sdk/js/js.php).

To remove it, close the tuner, remove its empty helper track from your projects, and remove the installed JSFX. Removing the plugin does not alter recorded audio. ReaTune remains available in REAPER's FX browser.
