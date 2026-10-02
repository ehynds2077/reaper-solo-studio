"""Frequency/time/level fidelity, bounded charts and quieter loudness goals."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import numpy as np
import spectrogram
import visuals
import worker
from test_visuals import write_wav, profile


class SpectrogramTests(unittest.TestCase):
    def test_tones_keep_time_frequency_power_and_stereo_antiphase(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'tone.wav'
            t = np.arange(48000 * 4) / 48000
            mono = np.where(t < 2, .5 * np.sin(2 * np.pi * 400 * t), .25 * np.sin(2 * np.pi * 2000 * t))
            results = []
            for polarity in (1, -1):
                write_wav(path, np.column_stack((mono, mono * polarity)))
                results.append(spectrogram.spectrum_over_time(path, max_columns=40))
            a, b = results
            np.testing.assert_allclose(a['power'], b['power'], rtol=.00001, atol=1e-12)
            centers = np.sqrt(a['frequency_edges'][:-1] * a['frequency_edges'][1:])
            self.assertAlmostEqual(centers[np.argmax(a['power'][:, 10])], 400, delta=25)
            self.assertAlmostEqual(centers[np.argmax(a['power'][:, 30])], 2000, delta=100)
            level1 = 10 * np.log10(a['power'][:, 10].sum())
            level2 = 10 * np.log10(a['power'][:, 30].sum())
            self.assertAlmostEqual(level1, -9.03, places=2)
            self.assertAlmostEqual(level1 - level2, 6.02, places=2)
            self.assertEqual(a['dbfs'].shape[1], 40)
            self.assertTrue(np.isfinite(a['dbfs']).all())

    def test_short_burst_between_buckets_is_not_skipped_and_silence_has_fixed_floor(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'burst.wav'; t = np.arange(48000 * 4) / 48000
            tone = np.where((t > 1.123) & (t < 1.143), .8 * np.sin(2 * np.pi * 1000 * t), 0)
            write_wav(path, np.column_stack((tone, tone)))
            result = spectrogram.spectrum_over_time(path, max_columns=8)
            self.assertGreater(result['dbfs'][:, 2].max(), -25)
            self.assertEqual(result['dbfs'][:, 6].max(), -90)

    def test_local_graphics_backfill_and_cache_need_no_api_or_daw_render(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder / 'render-1-test.wav'
            write_wav(source, np.zeros((48000 * 8, 2)))
            worker.write(folder / 'snapshot.json', {'bounds': [100, 108]})
            worker.write(folder / 'status.json', {'state': 'review'})
            (folder / 'events.jsonl').write_text(json.dumps({'kind': 'measurement', 'track': None,
                'bounds': [100, 108], 'render': source.name}) + '\n')
            with patch.object(worker, 'request', side_effect=AssertionError('No network')), \
                 patch.object(worker, 'analyze_audio', return_value=profile()):
                result = worker.generate_session_graphics(folder)
                self.assertEqual(set(result['views']), {'spectrogram', 'waterfall', 'dynamics'})
                for name in result['views'].values():
                    chart = folder / 'visuals' / name
                    self.assertTrue(chart.read_bytes().startswith(b'\x89PNG'))
                    self.assertLess(chart.stat().st_size, 2 * 1024 * 1024)
                with patch.object(spectrogram, 'spectrum_over_time', side_effect=AssertionError('Cache should avoid FFT')):
                    self.assertEqual(worker.generate_session_graphics(folder), result)
            self.assertEqual(len(visuals.plt.get_fignums()), 0)
            worker.write(folder / 'status.json', {'state': 'running'})
            with self.assertRaisesRegex(ValueError, 'active mixing pass'): worker.generate_session_graphics(folder)


class LoudnessGoalTests(unittest.TestCase):
    def test_loud_reference_does_not_force_a_limited_master(self):
        refs = [{'loudness': {'integrated_lufs': -8.9}}]
        good = {'loudness': {'integrated_lufs': -12, 'true_peak_dbtp': -1.1}}
        goal = worker.loudness_goal(refs)
        self.assertEqual(goal['target_lufs'], -12)
        self.assertEqual(goal['reference_lufs'], -8.9)
        self.assertEqual(worker.reference_issues(good, refs, -12), [])
        # Raw reference data remains honest; the completion check uses the target.
        self.assertAlmostEqual(worker.reference_comparison(good, refs)['metrics']['integrated_lufs']['delta_to_reference'], 3.1)
        loud = {'loudness': {'integrated_lufs': -9.8, 'true_peak_dbtp': -1.1}}
        self.assertIn('2.2 LU louder', worker.reference_issues(loud, refs, -12)[0])

    def test_quiet_references_and_explicit_targets_and_invalid_settings(self):
        self.assertEqual(worker.loudness_goal([{'loudness': {'integrated_lufs': -16}}])['target_lufs'], -16)
        self.assertEqual(worker.loudness_goal([], -14)['target_lufs'], -14)
        for value in (-25, -7, True, float('nan'), float('inf'), '-12'):
            with self.assertRaises(ValueError): worker.loudness_goal([], value)

    def test_model_completion_honors_lower_target_instead_of_chasing_reference(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            worker.write(folder / 'config.json', {'bounds': [0, 8], 'references': ['ref'], 'visual_analysis': False})
            worker.write(folder / 'ref.json', {'loudness': {'integrated_lufs': -9, 'true_peak_dbtp': -1}})
            requests = []
            def api(route, payload):
                requests.append(payload)
                return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured candidate.'}}]}
            session = worker.Session(folder, api)
            session.bridge = lambda *args: {'tracks': [], 'capabilities': {'mix_tools_version': 4}}
            session.measure = lambda *args, **kwargs: {'loudness': {'integrated_lufs': -12, 'true_peak_dbtp': -1.1}}
            with patch.object(worker, 'library', return_value={'references': [{'id': 'ref', 'profile': str(folder / 'ref.json')}]}), patch('charts.render_charts'):
                self.assertEqual(session.run(), 'review')
            self.assertEqual(session.completion_reason, 'measured_completion')
            self.assertEqual(len(requests), 1)
            context = json.loads(requests[0]['messages'][1]['content'])
            self.assertEqual(context['loudness_goal']['target_lufs'], -12)


if __name__ == '__main__': unittest.main()
