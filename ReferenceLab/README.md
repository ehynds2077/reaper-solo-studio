# Reference Lab

A local measurement experiment for comparing reference mixes before building AI
mix controls. It reads audio files, saves reusable analysis profiles, and makes
comparison charts and tables. It does not call a model, upload audio, change
REAPER, or process the source files in place.

Requires Python 3.9+, NumPy, Matplotlib, and `ffmpeg`/`ffprobe` on PATH. FFmpeg
needs its `ebur128` filter with true-peak support. The initial validation used
FFmpeg 7.1.1, NumPy 1.26.0, and Matplotlib 3.9.4 on macOS.

## Compare tracks

Create `ReferenceLab/Local/references.json` with entries like:

```json
[
  {"path": "/path/to/song-a.wav", "title": "Song A", "group": "Artist A"},
  {"path": "/path/to/song-b.wav", "title": "Song B", "group": "Artist B"}
]
```

From the repository root:

```sh
python3 ReferenceLab/analyze.py ReferenceLab/Local/references.json
```

Reports are saved under `ReferenceLab/Local/`:

- `overview.png`: tonal distribution, stereo difference by frequency, LUFS, LRA.
- `details.pdf`: overview plus per-song loudness and peak/RMS envelopes.
- `comparison.md` and `measurements.csv`: measurements and group ranges.
- `group-summary.json`: machine-readable group medians and observed ranges.
- `comparison.json` and `profiles/*.json`: reusable measured profiles and timelines.

The profile cache keys include the source SHA-256, requested excerpt, analysis
version, and FFmpeg version. Rerunning reuses those measurements. `title` and
`group` can change without reanalyzing the audio. The comparison uses the latest
manifest labels. `--output` can select another output folder; use an ignored
local location for private reference data. `--jobs` selects 1–4 parallel workers.

To compare sections rather than whole songs, add `start_seconds` and
`duration_seconds` to each manifest entry and name it accordingly. These are
independent per file, so choruses can be compared at different positions. The
meter and spectral measurements both cover exactly the requested excerpt.

## What the numbers mean

- **Loudness:** FFmpeg's EBU R128 scanner supplies integrated LUFS, momentary
  (400 ms) and short-term (3 s) timelines, loudness range (LRA), and true peak.
  Filter startup readings are excluded from the timelines.
- **Dynamics:** peak minus LUFS, peak minus full-excerpt RMS, and median 1-second
  crest factor are separately named. None is treated as an estimate of compressor
  gain reduction. Very short excerpts give limited evidence of dynamics.
- **Tone:** channel-averaged power spectra use a 16,384-sample Hann window with
  50% overlap at 48 kHz. Each frequency band's power is divided by the total power
  from 20 Hz to 20 kHz. This makes broad tonal distribution independent of overall
  gain; it is not perceptual loudness normalization, an EQ recommendation, or a
  count of instruments in that range. Louder passages contribute more energy.
- **Stereo:** zero-mean L/R correlation and side energy S²/(M²+S²), including
  side energy per frequency band. Spectrum analysis never folds to mono, so
  opposite-phase channels retain their spectral energy. Mono references have no
  stereo measurements; silent/undefined ratios are JSON null.
- **Grouping:** each artist/group is summarized independently and each track
  has equal weight within its group. The shaded chart range is the observed
  minimum–maximum, not statistical confidence. A large album cannot swamp a
  second artist's two tracks through pooled averaging.

Audio is decoded to 48 kHz float PCM in a temporary directory and removed after
measurement. Sources with more than two channels are rejected instead of silently
downmixed. High-frequency bands beyond the source's Nyquist limit are unavailable.
Original mastered loudness stays visible; only spectral energy ratios remove the
overall gain. No loudness-normalized audio exports are created.

Source music, private manifests, cached profiles, and reports are excluded from
Git. Keep that distinction when adding new files or changing `.gitignore`.

## Verification

```sh
python3 ReferenceLab/test_analysis.py
```

Known-signal tests cover RMS/peak/crest arithmetic, frequency-band concentration,
gain invariance, stereo phase, silence, real FFmpeg loudness and true-peak output,
excerpt boundaries, cached results, group counts, and report generation.

Measurement reference: [FFmpeg ebur128](https://ffmpeg.org/ffmpeg-filters.html#ebur128).
