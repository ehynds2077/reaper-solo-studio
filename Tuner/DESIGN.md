# Solo Studio Strobe

A REAPER-native JSFX tuner for Ethan's guitar and bass recording. The main interaction is slowing moving bands to a stop, with a numeric cents reading for confirmation. Equal temperament; no copied Peterson presets or proprietary algorithms.

Palette: deep blue `#172F42`, instrument-face blue `#24465C`, ivory text `#F3F1E9`, silver labels `#A8BBC8`, amber bands `#F0B85E`, teal in-tune indicator `#72C7B5`.

Type: Helvetica for controls and note; Menlo for changing numeric values so the layout stays still. Large note and cents align on one baseline. Three horizontal strobe bands occupy the full center width. Guitar-string buttons sit below them, followed by quiet reference/input/output controls.

Review: a generic tuner could put a large number over a progress bar. Here, the defining element is a three-band phase display driven by the actual signal against reference oscillators at 1x, 2x, and 4x the target frequency. Bands with no usable harmonic fade out. No celebratory animation or ornamental panels. Motion is the measurement.

Detection: FFT autocorrelation with normalized squared differences finds the fundamental; a fit across multiple periods reduces interpolation error in the cents display. The strobe itself follows measured phase, not an animation made from a rounded cents number. Guitar/bass single notes only, approximately 30–1400 Hz. Signal confidence and silence invalidate the reading instead of displaying a stale in-tune indication.

Integration: a dedicated track reads the selected recording set's first input, disables all output routing, and uses monitor-only recording mode. The original recording track's monitoring, effects, and input remain untouched. The launcher refuses to change routing during recording. Closing the window disarms the helper track. No interface is required to test the plugin using prerecorded fixtures.

Validation: generate known detuned tones, guitar-like harmonic plucks, low bass, noise, silence, and input-channel cases. Run those through the actual JSFX in REAPER and inspect machine-readable telemetry. Numerical test performance is not a claim about acoustic instruments or hardware clock calibration.
