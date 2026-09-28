# Tuner validation workbench

`results.txt` is the numeric result of running the instrumented production DSP through REAPER, including three sample rates, opposite-polarity input channels, silence/noise gates, transparent pass-through, mute, phase direction/rate, and manual/442 Hz reference targets. `measurements.json` has per-case maximum settled cents errors. `production-sha256.txt` identifies the tested production plugin.

`integration-results.txt` covers the production plugin's silent helper-track launcher and cleanup. Closing the test project also exercised the launcher's exit callback; the corrected version returned to the original session without an error dialog.

To reproduce:

1. Run `python3 make_fixtures.py` from this directory. It requires NumPy and creates deterministic 24-bit audio plus `Strobe QA.jsfx`. The QA copy adds diagnostic output channels; its analysis and original audio path are otherwise unchanged.
2. Temporarily copy `Strobe QA.jsfx` into REAPER's `Effects/Solo Studio/` directory. It is intentionally removed from the installed FX collection after testing because its extra outputs contain diagnostic signals, not program audio.
3. Remove the optional `preview.flag`, `integration.flag`, and `phase.flag` files. Load/run `Run tuner checks.lua` through REAPER's action list. All renders use a separate test project with no hardware outputs. The script saves and closes its own project, then restores the original tab.
4. Create an empty `phase.flag` file and run that same action to produce the additional phase/reference renders.
5. Run `python3 analyze_results.py` to check the rendered files and write the report.
6. To test the launcher, create `integration.flag` and run the action. At least one audio-device input must be available. This uses an isolated project, never routes test audio to hardware, and does not change the original recording project's input or monitoring settings.
7. Remove those mode flags and the installed QA copy afterward. A rerun may ask to overwrite generated render files; these files belong entirely to this test directory.

`preview.flag` instead invokes `Preview.lua`. On the first invocation it opens a silent production-plugin preview of a generated 110 Hz A2 tone. The next invocation while that preview project is active stops and saves it, logs the control values, closes the preview tab, and returns to the previous project. Its master has no hardware sends. The preview's controls can be tested without routing a real instrument.

All pitch errors are measured over the last 0.25 to 0.05 seconds of each generated case. The finite test set does not prove a universal tuning-accuracy specification.
