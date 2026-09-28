"""Known-signal checks for the measurement pipeline; no music fixtures needed."""
import json
import math
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

from analyze import RATE, analyze, signal_metrics
from report import aggregate, make_report


def tone(seconds=4, gain=.1):
    return gain * np.sin(2 * np.pi * 1000 * np.arange(round(seconds * RATE)) / RATE)


def wav(path, audio):
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(audio.shape[1]);file.setsampwidth(2);file.setframerate(RATE)
        file.writeframes(np.round(audio * 32767).astype('<i2').tobytes())


class AnalysisChecks(unittest.TestCase):
    def test_known_rms_peak_crest_and_band(self):
        row = signal_metrics(tone()[:, None], RATE)
        self.assertAlmostEqual(row['sample_peak_dbfs'], -20, places=4)
        self.assertAlmostEqual(row['rms_dbfs'], -23.0103, places=4)
        self.assertAlmostEqual(row['crest_db'], 3.0103, places=4)
        self.assertGreater(row['bands'][3]['energy_fraction'], .999)
        self.assertIsNone(row['lr_correlation'])

    def test_gain_does_not_change_tonal_distribution(self):
        a = signal_metrics(tone()[:, None], RATE)
        b = signal_metrics((tone() * 2)[:, None], RATE)
        self.assertAlmostEqual(b['rms_dbfs'] - a['rms_dbfs'], 20 * math.log10(2), places=6)
        np.testing.assert_allclose([x['energy_fraction'] for x in a['bands']], [x['energy_fraction'] for x in b['bands']])

    def test_phase_preserves_energy_but_changes_stereo_metrics(self):
        t = tone()
        mono = signal_metrics(np.column_stack([t, t]), RATE)
        anti = signal_metrics(np.column_stack([t, -t]), RATE)
        self.assertAlmostEqual(mono['lr_correlation'], 1)
        self.assertAlmostEqual(anti['lr_correlation'], -1)
        self.assertAlmostEqual(mono['side_energy_fraction'], 0)
        self.assertAlmostEqual(anti['side_energy_fraction'], 1)
        np.testing.assert_allclose([x['energy_fraction'] for x in mono['bands']], [x['energy_fraction'] for x in anti['bands']])

    def test_silence_has_undefined_ratios(self):
        row = signal_metrics(np.zeros((RATE, 2)), RATE)
        self.assertIsNone(row['rms_dbfs'])
        self.assertIsNone(row['side_energy_fraction'])
        self.assertIsNone(row['bands'][0]['energy_fraction'])
        json.dumps(row, allow_nan=False)

    def test_native_decode_meter_excerpt_cache_and_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary);source = folder / 'signal with spaces.wav'
            t = np.concatenate([tone(4, .01), tone(4, .1)])
            wav(source, np.column_stack([t, t]))
            low, low_path = analyze({'path': source, 'title': 'Quiet', 'group': 'A', 'duration_seconds': 4}, folder)
            high, high_path = analyze({'path': source, 'title': 'Loud', 'group': 'B', 'start_seconds': 4, 'duration_seconds': 4}, folder)
            self.assertNotEqual(low_path, high_path)
            self.assertAlmostEqual(high['duration_seconds'], 4)
            self.assertAlmostEqual(high['loudness']['integrated_lufs'], -20, delta=.2)
            self.assertAlmostEqual(high['loudness']['true_peak_dbtp'], -20, delta=.1)
            self.assertAlmostEqual(high['loudness']['integrated_lufs'] - low['loudness']['integrated_lufs'], 20, delta=.2)
            self.assertTrue(all(row['short_term_lufs'] is None for row in high['loudness']['timeline'] if row['seconds'] < 2.999))
            cached, _ = analyze({'path': source, 'title': 'Renamed', 'group': 'B', 'start_seconds': 4, 'duration_seconds': 4}, folder)
            self.assertEqual(cached['title'], 'Renamed')
            self.assertEqual(cached['loudness'], high['loudness'])
            make_report([low, high], folder)
            self.assertTrue((folder / 'overview.png').is_file())
            self.assertTrue((folder / 'details.pdf').is_file())
            _, groups = aggregate([low, high])
            self.assertEqual(groups['A']['tracks'], 1)
            self.assertEqual(groups['B']['tracks'], 1)


if __name__ == '__main__':
    unittest.main()
