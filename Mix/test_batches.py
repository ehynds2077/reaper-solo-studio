"""Batch protocol, dependency validation and model-loop tests; no network/audio."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import worker


def eq_operations(count=10):
    operations = []
    for i in range(count):
        track = 'track-%d' % i
        operations.extend([
            {'tool': 'add_effect', 'save_as': 'eq%d' % i,
             'arguments': {'track': track, 'plugin': 'VST: ReaEQ (Cockos)'}},
            {'tool': 'configure_eq', 'arguments': {'track': track, 'effect': '$eq%d' % i,
             'band': 'bell', 'band_index': 0, 'frequency_hz': 300, 'gain_db': -4}},
        ])
    return operations


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        worker.write(self.path / 'config.json', {'bounds': [10, 110], 'rounds': 4, 'visual_analysis': False})
        self.session = worker.Session(self.path)
        self.session.diagnostic_bounds = [30, 60]
        self.calls = []
        self.project = {'capabilities': {'mix_tools_version': 3}, 'tracks': [
            {'id': 'track-%d' % i, 'name': 'Guitar %d' % i, 'volume_db': -6, 'pan': 0}
            for i in range(10)]}

        def bridge(name, args):
            self.calls.append((name, copy.deepcopy(args)))
            self.session.calls += 1
            if name == 'inspect_project':
                return self.project
            if name == 'add_effect':
                return {'effect': '{FX-%d}' % len(self.calls), 'plugin': args['plugin']}
            return {'ok': True}
        self.session.bridge = bridge

    def batch(self, operations):
        return self.session.execute_tool('apply_mix_batch', {'operations': operations})

    def test_ten_eqs_added_and_configured_without_model_round_or_render_between(self):
        plan = eq_operations()
        result = self.batch(plan)
        self.assertEqual(result['completed'], 20)
        self.assertEqual(len(result['effects']), 10)
        self.assertEqual(len(self.calls), 20)
        for i in range(10):
            self.assertEqual(self.calls[i * 2 + 1][1]['effect'], '{FX-%d}' % (i * 2 + 1))
            self.assertEqual(result['effects']['eq%d' % i]['track'], 'track-%d' % i)
        self.assertEqual(plan, eq_operations())  # Alias substitution does not mutate model input.
        self.assertFalse(any('measure' in name for name, _ in self.calls))

    def test_invalid_last_operation_rejects_whole_plan_before_mutating(self):
        for change in ({'gain_db': 13}, {'gain_db': float('nan')}, {'gain_db': True},
                       {'shell': 'ignored'}, {'frequency_hz': 0}):
            plan = eq_operations(); plan[-1]['arguments'].update(change)
            with self.assertRaises(ValueError): self.batch(plan)
            self.assertEqual(self.calls, [])
        for plan in ([], eq_operations(33), [{'tool': 'apply_mix_batch', 'arguments': {'operations': []}}],
                     [{'tool': 'measure_mix', 'arguments': {}}], [{'tool': 'delete_track', 'arguments': {}}]):
            with self.assertRaises(ValueError): self.batch(plan)
            self.assertEqual(self.calls, [])

    def test_alias_preflight_rejects_forward_missing_duplicate_and_cross_track_refs(self):
        bad = []
        plan = eq_operations(2); plan[1]['arguments']['effect'] = '$eq1'; bad.append(plan)
        plan = eq_operations(2); plan[-1]['arguments']['effect'] = '$missing'; bad.append(plan)
        plan = eq_operations(2); plan[-1]['arguments']['track'] = 'track-0'; bad.append(plan)
        plan = eq_operations(2); plan[2]['save_as'] = 'eq0'; bad.append(plan)
        plan = eq_operations(1); plan[0]['save_as'] = '$bad'; bad.append(plan)
        for plan in bad:
            with self.assertRaises(ValueError): self.batch(plan)
            self.assertEqual(self.calls, [])

    def test_aliases_do_not_leak_between_calls_and_real_guids_can_be_reused(self):
        result = self.batch(eq_operations(1))
        update = eq_operations(1)[1]
        with self.assertRaises(ValueError): self.batch([update])
        update['arguments']['effect'] = result['effects']['eq0']['effect']
        self.assertEqual(self.batch([update])['completed'], 1)

    def test_first_native_failure_stops_remainder_and_reports_applied_ids(self):
        bridge = self.session.bridge
        def failing(name, args):
            if name == 'configure_eq':
                self.calls.append((name, args)); return {'error': 'Unsupported parameter layout'}
            return bridge(name, args)
        self.session.bridge = failing
        result = self.batch(eq_operations(10))
        self.assertEqual((result['completed'], result['failed_index'], result['skipped']), (1, 2, 18))
        self.assertEqual(len(self.calls), 2)
        self.assertIn('Unsupported parameter layout', result['results'][1]['result']['error'])
        self.assertIn('eq0', result['effects'])
        self.assertIn('remain applied', result['error'])

    def test_fatal_or_cancelled_bridge_stops_batch_immediately(self):
        bridge = self.session.bridge
        def cancel_after_add(name, args):
            if self.calls:
                raise RuntimeError('Session cancelled')
            return bridge(name, args)
        self.session.bridge = cancel_after_add
        with self.assertRaisesRegex(RuntimeError, 'cancelled'): self.batch(eq_operations())
        self.assertEqual(len(self.calls), 1)

    def test_batch_budget_and_existing_cancel_are_checked_before_bridge(self):
        self.session.calls = worker.MAX_BRIDGE_CALLS - 1
        with self.assertRaises(ValueError): self.batch(eq_operations(1))
        self.assertEqual(self.calls, [])
        (self.path / 'cancel').touch()
        with self.assertRaises(RuntimeError): self.batch(eq_operations(1))
        self.assertEqual(self.calls, [])

    def test_inspect_effects_returns_pages_and_individual_errors_without_edits(self):
        requests = [{'track': 'track-0', 'effect': '{a}'},
                    {'track': 'track-1', 'effect': '{b}', 'start_parameter': 96}]
        def bridge(name, args):
            self.calls.append((name, args))
            return {'error': 'Not owned'} if args['effect'] == '{b}' else {'parameters': [{'name': 'Gain'}]}
        self.session.bridge = bridge
        result = self.session.execute_tool('inspect_effects', {'effects': requests})
        self.assertEqual([name for name, _ in self.calls], ['inspect_effect', 'inspect_effect'])
        self.assertEqual(result['effects'][1]['start_parameter'], 96)
        self.assertEqual(result['effects'][1]['result']['error'], 'Not owned')
        self.assertNotIn('error', result)

    def test_measure_tracks_compares_same_window_with_current_settings(self):
        windows = []
        def measure(label, track, window):
            windows.append((track, window))
            return {'track': track, 'measurement_bounds': window,
                    'loudness': {'integrated_lufs': -18, 'true_peak_dbtp': -3}, 'bands': []}
        self.session.measure = measure
        result = self.session.execute_tool('measure_tracks', {'tracks': ['track-0', 'track-1']})
        self.assertEqual(windows, [('track-0', [30, 60]), ('track-1', [30, 60])])
        self.assertEqual(len(result['profiles']), 2)
        self.assertEqual(result['summary'][1]['name'], 'Guitar 1')
        self.assertEqual(result['summary'][1]['volume_db'], -6)
        self.assertEqual(result['errors'], [])
        self.assertIn('shared returns', result['scope'])
        result = self.session.execute_tool('measure_tracks', {'tracks': ['track-0'], 'full_passage': True})
        self.assertEqual(result['measurement_bounds'], [10, 110])

    def test_measurement_batch_rejects_invalid_plan_before_any_render(self):
        self.session.measure = lambda *a, **k: self.fail('Invalid plan rendered audio')
        for args in ({'tracks': ['track-0', 'track-0']}, {'tracks': ['MASTER']},
                     {'tracks': ['track-0', 'unknown']}, {'tracks': ['track-0'], 'start_seconds': 0},
                     {'tracks': ['track-%d' % i for i in range(17)]}):
            with self.assertRaises(ValueError): self.session.execute_tool('measure_tracks', args)

    def test_muted_track_failure_does_not_discard_other_measurements(self):
        def measure(label, track, window):
            if track == 'track-0': raise ValueError('Track is muted')
            return {'track': track, 'loudness': {'integrated_lufs': -20}}
        self.session.measure = measure
        result = self.session.execute_tool('measure_tracks', {'tracks': ['track-0', 'track-1']})
        self.assertEqual(len(result['profiles']), 1)
        self.assertEqual(result['errors'][0]['track'], 'track-0')
        result = self.session.execute_tool('measure_tracks', {'tracks': ['track-0']})
        self.assertIn('error', result)

    def test_model_loop_creates_ten_configured_eqs_in_one_response_then_measures(self):
        self.session.maximum_lufs = -14  # Protocol fixture already meets its chosen target.
        requests = []
        def api(route, payload):
            requests.append(copy.deepcopy(payload))
            if len(requests) == 1:
                return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                    {'id': 'eqs', 'function': {'name': 'apply_mix_batch', 'arguments': json.dumps({'operations': eq_operations()})}},
                    {'id': 'meter', 'function': {'name': 'measure_mix', 'arguments': '{}'}},
                ]}}]}
            return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured pass complete.'}}]}
        self.session.api = api
        measured_after = []
        def measure(*args, **kwargs):
            measured_after.append(len(self.calls))
            return {'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}}
        self.session.measure = measure
        with patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
            self.assertEqual(self.session.run(), 'review')
        self.assertEqual(len(requests), 2)
        self.assertEqual(measured_after, [1, 21, 21, 21])
        results = [json.loads(m['content']) for m in requests[1]['messages'] if m['role'] == 'tool']
        self.assertEqual(results[0]['completed'], 20)
        self.assertEqual(len(results[0]['effects']), 10)


if __name__ == '__main__':
    unittest.main()
