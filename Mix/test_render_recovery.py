"""Never cache failed loudness; bounded recovery and no AI edits into silence."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import worker

VALID = {'duration_seconds': 8, 'rms_dbfs': -18,
         'loudness': {'integrated_lufs': -16, 'true_peak_dbtp': -2}}
SILENT = {'duration_seconds': 8, 'rms_dbfs': None,
          'loudness': {'integrated_lufs': None, 'true_peak_dbtp': None}}


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        worker.write(self.path / 'config.json', {'bounds': [0, 8], 'visual_analysis': False})
        self.session = worker.Session(self.path)
        self.project = {'tracks': [], 'capabilities': {'mix_tools_version': 3, 'silent_render_recovery': True}}
        self.session.project = self.project
        self.calls = []; self.renders = 0
        def bridge(name, args):
            self.calls.append((name, args))
            if name == 'inspect_project': return self.project
            if name in ('measure_mix', 'measure_track'):
                self.renders += 1
                return {'path': str(self.path / ('render-%d.wav' % self.renders)), 'scope': 'Solo-in-place'}
            return {'ok': True}
        self.session.bridge = bridge

    def test_one_fresh_retry_recovers_without_mixing_edits_or_failed_cache(self):
        with patch.object(worker, 'analyze_audio', side_effect=[copy.deepcopy(SILENT), copy.deepcopy(VALID)]):
            result = self.session.measure('Candidate')
        self.assertEqual(result['loudness']['integrated_lufs'], -16)
        self.assertEqual([n for n, _ in self.calls], ['measure_mix', 'discard_measurements', 'recover_silent_render', 'measure_mix'])
        self.assertEqual(len(self.session.measurements), 1)
        self.assertEqual(list(self.session.analysis_cache), [str((self.path / 'render-2.wav').resolve())])
        self.assertIsNone(self.session.measurement_error)
        self.assertEqual([t['valid'] for t in self.session.timings], [False, True])
        self.assertTrue(self.session.timings[-1]['recovered'])

    def test_persistent_full_silence_stops_after_one_retry_and_clears_both_caches(self):
        self.session.analysis_cache['old'] = VALID
        with patch.object(worker, 'analyze_audio', return_value=copy.deepcopy(SILENT)):
            with self.assertRaisesRegex(RuntimeError, 'full passage is still silent'):
                self.session.measure('Candidate')
        self.assertEqual(self.renders, 2)
        self.assertEqual([n for n, _ in self.calls].count('recover_silent_render'), 1)
        self.assertEqual([n for n, _ in self.calls].count('discard_measurements'), 2)
        self.assertEqual(self.session.analysis_cache, {})
        self.assertEqual(self.session.measurements, [])
        self.assertTrue(worker.read(self.path / 'failed-measurement.json')['retried'])
        self.assertTrue(worker.read(self.path / 'status.json')['measurement_error'])

    def test_real_zero_lufs_is_a_number_and_does_not_trigger_silence_recovery(self):
        profile = copy.deepcopy(VALID); profile['loudness']['integrated_lufs'] = 0
        with patch.object(worker, 'analyze_audio', return_value=profile):
            self.assertEqual(self.session.measure('Loud')['loudness']['integrated_lufs'], 0)
        self.assertEqual([n for n, _ in self.calls], ['measure_mix'])

    def test_quiet_or_empty_track_is_an_explicit_tool_error_without_engine_restart(self):
        with patch.object(worker, 'analyze_audio', return_value=copy.deepcopy(SILENT)):
            with self.assertRaisesRegex(ValueError, 'do not boost silence'):
                self.session.measure('Track', 'track-id')
        self.assertEqual([n for n, _ in self.calls], ['measure_track', 'discard_measurements'])
        self.assertIsNone(self.session.measurement_error)
        self.assertEqual(self.session.analysis_cache, {})

    def test_silent_diagnostic_locks_edits_until_valid_mix_measurement(self):
        self.session.config['bounds'] = [0, 80]
        with patch.object(worker, 'analyze_audio', return_value=copy.deepcopy(SILENT)):
            with self.assertRaises(ValueError): self.session.measure('Diagnostic', window=[0, 8])
        before = len(self.calls)
        args = {'track': 'guitar', 'volume_db': 24, 'pan': 0}
        for name, data in [('set_track_mix', args), ('apply_mix_batch', {'operations': [{'tool': 'set_track_mix', 'arguments': args}]})]:
            with self.assertRaisesRegex(ValueError, 'paused'): self.session.execute_tool(name, data)
        self.assertEqual(len(self.calls), before)
        with patch.object(worker, 'analyze_audio', return_value=copy.deepcopy(VALID)):
            self.session.execute_tool('measure_mix', {'start_seconds': 10, 'duration_seconds': 8})
        self.session.execute_tool('set_track_mix', args)
        self.assertEqual(self.calls[-1][0], 'set_track_mix')

    def test_engine_failure_does_not_retry_or_change_mix(self):
        bridge = self.session.bridge
        self.session.bridge = lambda n, a: {'error': 'Stop other project playback'} if n == 'recover_silent_render' else bridge(n, a)
        with patch.object(worker, 'analyze_audio', return_value=copy.deepcopy(SILENT)):
            with self.assertRaisesRegex(RuntimeError, 'Stop other project playback'):
                self.session.measure('Candidate')
        self.assertEqual(self.renders, 1)

    def test_model_loop_stops_spending_rounds_on_persistent_silence(self):
        requests = []
        def api(route, payload):
            requests.append(payload)
            return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                {'id': 'meter', 'function': {'name': 'measure_mix', 'arguments': '{"full_passage":true}'}},
                {'id': 'boost', 'function': {'name': 'set_track_mix', 'arguments': '{"track":"g","volume_db":24,"pan":0}'}},
            ]}}]}
        self.session.api = api
        with patch.object(worker, 'analyze_audio', side_effect=[copy.deepcopy(VALID), copy.deepcopy(SILENT), copy.deepcopy(SILENT)]), \
             patch.object(worker, 'library', return_value={'references': []}):
            self.assertEqual(self.session.run(), 'error')
        self.assertEqual(len(requests), 1)
        self.assertNotIn('set_track_mix', [n for n, _ in self.calls])
        self.assertEqual(len(self.session.measurements), 1)
        self.assertEqual(self.session.analysis_cache, {})


if __name__ == '__main__':
    unittest.main()
