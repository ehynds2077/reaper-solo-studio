"""Phrase editing, full-resolution evidence and bounded diagnostic planning."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import leveling
import planning
import worker


def profile(levels):
    return {'duration_seconds': len(levels), 'loudness': {'integrated_lufs': -16, 'true_peak_dbtp': -2},
            'envelope_1s': [{'seconds': i, 'rms_dbfs': value} for i, value in enumerate(levels)]}


class PlanningTests(unittest.TestCase):
    def test_continuous_curve_partially_reduces_variation_and_respects_slew_and_gaps(self):
        source = profile([-24] * 30 + [-30] * 30 + [None] * 10 + [-18] * 30 + [-24] * 30)
        plan = planning.level_curve(source, [], [0, 130])
        self.assertGreater(plan['predicted_spread_db'], 4)
        self.assertLess(plan['predicted_spread_db'], 8)
        self.assertEqual(plan['before_spread_db'], 12)
        self.assertAlmostEqual(planning.trim_value(plan['points'], 40), 3)
        self.assertAlmostEqual(planning.trim_value(plan['points'], 80), -3)
        for t in (60.5, 61, 65.5, 69.5):
            self.assertEqual(planning.trim_value(plan['points'], t), 0)
        for left, right in zip(plan['points'], plan['points'][1:]):
            self.assertLessEqual(abs(right['db'] - left['db']), 1.5 * (right['seconds'] - left['seconds']) + .000001)
        self.assertEqual(plan['points'][0], {'seconds': 0, 'db': 0})
        self.assertEqual(plan['points'][-1], {'seconds': 130, 'db': 0})

    def test_small_range_uses_song_context_and_preserves_other_existing_rides(self):
        source = profile([-24] * 30 + [-30] * 10 + [-24] * 90)
        existing = planning.phrase_envelope([], [{'start_seconds': 70, 'end_seconds': 75, 'gain_db': 2}], [0, 130])
        plan = planning.level_curve(source, existing, [0, 130], start=32, end=34)
        self.assertGreater(planning.trim_value(plan['points'], 33), .5)
        for t in (0, 10, 31.9, 34, 60, 69.7, 70, 72, 75.2, 100, 130):
            self.assertEqual(planning.trim_value(plan['points'], t), planning.trim_value(existing, t))
        unchanged = planning.level_curve(source, existing, [0, 130], strength=0)
        for t in range(131):
            self.assertAlmostEqual(planning.trim_value(unchanged['points'], t), planning.trim_value(existing, t))

    def test_limits_silence_rejection_and_long_silent_runs(self):
        source = profile([-24] * 20 + [-44] * 20 + [-9] * 20 + [None] * 400 + [-24] * 20)
        plan = planning.level_curve(source, [], [0, 480], max_boost_db=2, max_cut_db=4, strength=.9)
        self.assertTrue(all(-4 <= point['db'] <= 2 for point in plan['points']))
        self.assertLess(len(plan['points']), 100)
        self.assertEqual(planning.trim_value(plan['points'], 200), 0)
        with self.assertRaisesRegex(ValueError, 'No active audio'):
            planning.level_curve(source, [], [0, 480], start=100, end=110)
        with self.assertRaisesRegex(ValueError, 'Too little active audio'):
            planning.level_curve(profile([None] * 30), [], [0, 30])

    def test_analysis_keeps_full_resolution_and_catches_phrase_lost_by_prompt_sampling(self):
        source = profile([-24] * 98 + [-36] * 4 + [-24] * 198)
        source['source_name'] = '/private/recording.wav'
        with patch('analyze.analyze', return_value=(source, Path('cached.json'))):
            measured = worker.analyze_audio(Path('audio.wav'), Path('.'), 'Test')
        self.assertEqual(len(measured['envelope_1s']), 300)
        self.assertNotIn('source_name', measured)
        report = leveling.level_report(measured, profile([-18] * 300), [0, 300], [])
        phrase = next(row for row in report['windows'] if row['start_seconds'] == 100)
        self.assertTrue(phrase['review_level_change'])
        self.assertEqual(phrase['active_fraction'], 1)
        sent = planning.model_evidence({'reports': [measured]})
        self.assertLessEqual(len(sent['reports'][0]['envelope_1s']), 90)
        self.assertEqual(len(measured['envelope_1s']), 300)
        self.assertEqual(sent['reports'][0]['envelope_summary_stride_seconds'], 4)

    def test_phrase_gain_is_held_and_other_rides_are_preserved_idempotently(self):
        original = [{'seconds': 0, 'db': 0}, {'seconds': 10, 'db': -2}, {'seconds': 60, 'db': -2},
                    {'seconds': 70, 'db': 0}, {'seconds': 75, 'db': 2}, {'seconds': 80, 'db': 0}, {'seconds': 100, 'db': 0}]
        rides = [{'start_seconds': 20, 'end_seconds': 24, 'gain_db': 3}]
        result = planning.phrase_envelope(original, rides, [0, 100])
        for t in (20, 21, 22, 23, 24):
            self.assertEqual(planning.trim_value(result, t), 3)
        for t in (0, 10, 19.5, 24.5, 40, 70, 75, 80, 100):
            self.assertEqual(planning.trim_value(result, t), planning.trim_value(original, t))
        self.assertEqual(result, planning.phrase_envelope(result, rides, [0, 100]))
        self.assertEqual(len(original), 7)

    def test_ambiguous_overlapping_rides_and_passage_endpoints_are_rejected(self):
        for rides in ([{'start_seconds': 0, 'end_seconds': 4, 'gain_db': 3}],
                      [{'start_seconds': 20, 'end_seconds': 101, 'gain_db': 3}],
                      [{'start_seconds': 20, 'end_seconds': 24, 'gain_db': 3},
                       {'start_seconds': 24, 'end_seconds': 28, 'gain_db': -2}]):
            with self.assertRaises(ValueError): planning.phrase_envelope([], rides, [0, 100])
        with self.assertRaises(ValueError):
            planning.phrase_envelope([{'seconds': 0, 'db': 1}, {'seconds': 100, 'db': 0}], [], [0, 100])

    def test_only_changed_intervals_are_checked_with_context_and_bounded_duration(self):
        before = [{'seconds': 100, 'db': 0}, {'seconds': 400, 'db': 0}]
        after = planning.phrase_envelope(before, [{'start_seconds': 244, 'end_seconds': 248, 'gain_db': 3}], [100, 400])
        spans = planning.changed_trim_spans(before, after, [100, 400])
        self.assertEqual(spans, [[243.5, 248.5]])
        windows = planning.check_windows(spans, [100, 400])
        self.assertEqual(len(windows), 1)
        self.assertLessEqual(windows[0][0], 240)
        self.assertGreaterEqual(windows[0][1], 252)
        windows = planning.check_windows([[101, 103], [190, 196], [300, 330], [398, 400]], [100, 400])
        self.assertEqual(len(windows), 3)
        self.assertTrue(all(100 <= a < b <= 400 and 3 <= b - a <= 24 for a, b in windows))
        self.assertLessEqual(windows[0][0], 101)
        self.assertEqual(windows[-1][1], 400)
        self.assertEqual(planning.changed_trim_spans(after, after, [100, 400]), [])

    def test_history_preserves_linkage_outcomes_and_recent_dense_evidence(self):
        messages = [{'role': 'system', 'content': 'Instructions'}]
        for i in range(12):
            messages.append({'role': 'tool', 'tool_call_id': str(i), 'content': json.dumps({
                **profile([-20] * 90), 'track': str(i), 'measurement_bounds': [100, 190]})})
        messages.append({'role': 'tool', 'tool_call_id': 'edit', 'content': '{"effect":"keep-this-guid"}'})
        original = copy.deepcopy(messages)
        planning.compact_history(messages)
        self.assertEqual([row.get('tool_call_id') for row in messages], [row.get('tool_call_id') for row in original])
        for row in messages[1:7]:
            value = json.loads(row['content'])
            self.assertNotIn('envelope_1s', value)
            self.assertEqual(value['measurement_bounds'], [100, 190])
            self.assertEqual(value['loudness']['integrated_lufs'], -16)
        self.assertEqual(messages[7:], original[7:])


class PlanningWorkflowTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        worker.write(self.path / 'config.json', {'bounds': [100, 400], 'visual_analysis': False})
        self.session = worker.Session(self.path)
        self.project = {'tracks': [{'id': key, 'name': key, 'items': 1} for key in ('Vocal', 'Guitar')]}
        self.session.project = self.project
        self.session.level_targets = leveling.targets(self.project)
        self.calls = []; self.windows = []
        def bridge(name, args):
            self.calls.append((name, copy.deepcopy(args)))
            return self.project if name == 'inspect_project' else {'ok': True}
        self.session.bridge = bridge
        def measure(label, track_id=None, window=None):
            window = window or [100, 400]
            self.windows.append((track_id, list(window)))
            return profile([-24 if track_id else -18] * int(window[1] - window[0]))
        self.session.measure = measure

    def analyze(self, stage='plan'):
        return self.session.execute_tool('analyze_track_levels', {'tracks': ['Vocal', 'Guitar'], 'stage': stage})

    def ride(self):
        return self.session.execute_tool('set_phrase_rides', {'track': 'Guitar', 'rides': [
            {'start_seconds': 244, 'end_seconds': 248, 'gain_db': 3}]})

    def test_curve_preview_reuses_full_baseline_and_batch_applies_once(self):
        self.analyze(); self.windows.clear(); self.calls.clear()
        plans = [self.session.execute_tool('plan_level_automation', {'track': track}) for track in ('Vocal', 'Guitar')]
        self.assertEqual(self.windows, [])
        self.assertTrue(all(name == 'inspect_project' for name, _ in self.calls))
        ids = [plan['plan_id'] for plan in plans]
        self.assertNotIn('points', plans[0])
        result = self.session.execute_tool('apply_level_automation', {'plan_ids': ids})
        self.assertEqual(len(result['results']), 2)
        self.assertEqual(self.session.mix_revision, 2)
        self.calls.clear()
        replay = self.session.execute_tool('apply_level_automation', {'plan_ids': ids})
        self.assertTrue(all(row['already_applied'] for row in replay['results']))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.session.mix_revision, 2)

    def test_curve_plan_staleness_rejects_entire_batch_before_editing(self):
        plan = self.session.execute_tool('plan_level_automation', {'track': 'Vocal'})
        self.ride(); self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'stale'):
            self.session.execute_tool('apply_level_automation', {'plan_ids': [plan['plan_id']]})
        self.assertEqual(self.calls, [])
        for args in ({'track': 'Vocal', 'strength': 1}, {'track': 'Vocal', 'window_seconds': 0},
                     {'track': 'Vocal', 'slew_db_per_second': float('nan')}):
            with self.assertRaises(ValueError): self.session.execute_tool('plan_level_automation', args)

    def test_curve_batch_native_failure_reports_completed_and_stale_remainder(self):
        plans = [self.session.execute_tool('plan_level_automation', {'track': track}) for track in ('Vocal', 'Guitar')]
        bridge = self.session.bridge
        self.session.bridge = lambda name, args: {'error': 'Native failure'} if name == 'set_trim_automation' and args['track'] == 'Guitar' else bridge(name, args)
        result = self.session.execute_tool('apply_level_automation', {'plan_ids': [p['plan_id'] for p in plans]})
        self.assertIn('error', result)
        self.assertIn('applied_revision', self.session.level_plans[plans[0]['plan_id']])
        self.assertNotIn('applied_revision', self.session.level_plans[plans[1]['plan_id']])
        with self.assertRaisesRegex(ValueError, 'stale'):
            self.session.execute_tool('apply_level_automation', {'plan_ids': [plans[1]['plan_id']]})

    def test_refinement_uses_short_real_renders_but_final_review_requires_full_passage(self):
        self.analyze(); self.assertEqual(len(self.windows), 3)
        self.ride(); self.windows.clear()
        result = self.analyze()
        self.assertTrue(result['reports'][0]['skipped_unchanged_source'])
        self.assertEqual(result['reports'][1]['verification_scope'], 'diagnostic')
        self.assertEqual([track for track, _ in self.windows], [None, 'Guitar'])
        self.assertTrue(all(b - a <= 24 for _, (a, b) in self.windows))
        with self.assertRaisesRegex(ValueError, 'stage=verify'):
            self.session.execute_tool('review_level_balance', {'track': 'Guitar', 'decision': 'automated', 'reason': 'Short check.'})
        self.windows.clear(); self.analyze('verify')
        self.assertEqual(self.windows, [(None, [100, 400]), ('Vocal', [100, 400]), ('Guitar', [100, 400])])
        self.session.execute_tool('review_level_balance', {'track': 'Guitar', 'decision': 'automated', 'reason': 'Full-passage verification after the phrase ride.'})

    def test_idempotent_ride_preserves_revision_and_existing_evidence(self):
        self.ride(); revision = self.session.mix_revision; self.calls.clear()
        self.assertTrue(self.ride()['unchanged'])
        self.assertEqual(self.session.mix_revision, revision)
        self.assertEqual([name for name, _ in self.calls], ['inspect_project'])

    def test_global_processing_gets_short_source_checks_then_full_final_verification(self):
        self.analyze(); self.windows.clear()
        self.session.execute_tool('set_track_mix', {'track': 'Guitar', 'volume_db': -6, 'pan': 0})
        result = self.analyze()
        self.assertTrue(all(not row.get('skipped_unchanged_source') for row in result['reports']))
        self.assertEqual(len(self.windows), 4)
        self.assertTrue(all(b - a <= 24 for _, (a, b) in self.windows))
        self.assertEqual(len(self.session.leveling_issues()), 2)

    def test_failed_diagnostic_cannot_be_recorded_as_a_full_song_review(self):
        self.analyze(); self.ride()
        self.session.measure = lambda *args, **kwargs: (_ for _ in ()).throw(ValueError('Silent diagnostic'))
        result = self.analyze()
        self.assertTrue(result['errors'])
        self.assertNotEqual(self.session.level_reports['Guitar']['revision'], self.session.mix_revision)
        with self.assertRaisesRegex(ValueError, 'stage=verify'):
            self.session.execute_tool('review_level_balance', {'track': 'Guitar', 'decision': 'unmeasurable', 'reason': 'Short check failed.'})


if __name__ == '__main__':
    unittest.main()
