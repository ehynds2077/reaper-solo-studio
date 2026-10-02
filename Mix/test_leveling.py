"""Level evidence and mandatory agent workflow checks; no network calls."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import leveling
import worker


def profile(levels):
    return {'duration_seconds': len(levels), 'loudness': {'integrated_lufs': -16, 'true_peak_dbtp': -2},
            'envelope_1s': [{'seconds': i, 'rms_dbfs': value} for i, value in enumerate(levels)]}


class LevelEvidenceTests(unittest.TestCase):
    def test_static_zero_faders_are_skipped_but_automation_sends_and_quiet_sources_remain(self):
        project = {'tracks': [
            {'id': 'scratch', 'name': 'Scratch guitar', 'items': 2, 'fader_silent': True},
            {'id': 'auto', 'name': 'Vocal', 'items': 2, 'fader_silent': True, 'volume_automated': True},
            {'id': 'send', 'name': 'Guitar', 'items': 2, 'fader_silent': True, 'sends': [{'destination': 'bus'}]},
            {'id': 'quiet', 'name': 'Guitar', 'items': 2, 'fader_silent': False, 'volume_db': -90},
            {'id': 'old', 'name': 'Vocal', 'items': 2, 'volume_db': -150}]}
        self.assertEqual([row['track'] for row in leveling.targets(project)], ['auto', 'send', 'quiet', 'old'])

    def test_quiet_phrase_and_balance_change_outside_diagnostic_window(self):
        track = profile([-24] * 48 + [None] * 8 + [-33] * 16 + [-24] * 48)
        mix = profile([-18] * 120)
        report = leveling.level_report(track, mix, [100, 220], [
            {'name': 'Quiet phrase', 'start_seconds': 156, 'end_seconds': 172}])
        phrase = report['sections'][0]
        self.assertEqual((phrase['start_seconds'], phrase['end_seconds']), (156, 172))
        self.assertEqual(phrase['level_delta_db'], -9)
        self.assertEqual(phrase['balance_delta_db'], -9)
        self.assertTrue(phrase['review_level_change'])
        self.assertGreater(report['review_windows'], 0)
        gaps = [row for row in report['windows'] if 148 <= row['start_seconds'] < 156]
        self.assertTrue(gaps)
        self.assertTrue(all(not row['review_level_change'] and row['active_samples'] == 0 for row in gaps))

    def test_arrangement_lift_is_evidence_not_an_automatic_gain_move(self):
        report = leveling.level_report(profile([-24] * 40 + [-18] * 40),
                                       profile([-18] * 40 + [-12] * 40), [0, 80], [])
        self.assertTrue(all(row['balance_delta_db'] == 0 for row in report['windows']))
        self.assertGreater(report['review_windows'], 0)
        self.assertNotIn('automation_points', report)
        self.assertIn('not required gain corrections', report['interpretation'])

    def test_noise_gaps_and_sparse_missing_measurements_are_not_quiet_phrases(self):
        report = leveling.level_report(profile([-20] * 12 + [-58] * 12 + [None] * 12),
                                       profile([-15] * 36), [0, 36], [])
        self.assertEqual(report['active_samples'], 12)
        self.assertEqual(report['review_windows'], 0)
        for levels in ([None] * 16, [-90] * 16, [float('nan')] * 16, [False] * 16):
            with self.assertRaises(ValueError):
                leveling.level_report(profile(levels), profile([-18] * 16), [0, 16], [])
        json.dumps(report, allow_nan=False)

    def test_reports_are_bounded_and_do_not_include_file_metadata(self):
        source = profile([-24] * 600); source['source_name'] = '/private/song.wav'
        regions = [{'name': str(i), 'start_seconds': i, 'end_seconds': i + 1} for i in range(90)]
        report = leveling.level_report(source, profile([-18] * 600), [0, 600], regions)
        self.assertLessEqual(len(report['windows']), 80)
        self.assertEqual(len(report['sections']), 64)
        self.assertTrue(report['sections_truncated'])
        self.assertNotIn('/private/', json.dumps(report))

    def test_roles_skip_muted_empty_returns_and_duplicate_parent_buses(self):
        project = {'tracks': [
            {'id': 'bus', 'name': 'Vocals', 'items': 0},
            {'id': 'lead', 'name': 'Lead vocal', 'items': 3, 'parent': 'bus'},
            {'id': 'gtr', 'name': 'Electric guitar 2', 'items': 2},
            {'id': 'empty', 'name': 'Acoustic guitar', 'items': 0},
            {'id': 'outside', 'name': 'Guitar intro', 'items': 3, 'playing_items_in_passage': 0},
            {'id': 'muted', 'name': 'Backing vox', 'items': 3, 'muted': True},
            {'id': 'kit', 'name': 'Drums', 'items': 1},
            {'id': 'mbus', 'name': 'Muted bus', 'muted': True, 'items': 0},
            {'id': 'hidden', 'name': 'Guitar', 'items': 2, 'parent': 'mbus'},
            {'id': 'vbus', 'name': 'Backing vocal bus', 'items': 0},
            {'id': 'unnamed', 'name': 'Audio 1', 'items': 4, 'parent': 'vbus'}]}
        self.assertEqual([row['track'] for row in leveling.targets(project)], ['lead', 'gtr', 'vbus'])


class LevelWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        worker.write(self.path / 'config.json', {'bounds': [100, 180], 'rounds': 3, 'visual_analysis': False})
        self.session = worker.Session(self.path)
        self.project = {'capabilities': {'mix_tools_version': 4}, 'tracks': [
            {'id': 'vocal', 'name': 'Lead vocal', 'items': 1, 'volume_db': -6, 'pan': 0},
            {'id': 'guitar', 'name': 'Guitar', 'items': 1, 'volume_db': -6, 'pan': 0}]}
        self.calls = []; self.windows = []
        def bridge(name, args):
            self.calls.append((name, copy.deepcopy(args)))
            return self.project if name == 'inspect_project' else {'ok': True}
        self.session.bridge = bridge
        self.session.level_targets = leveling.targets(self.project)
        def measure(label, track_id=None, window=None):
            self.windows.append((track_id, window))
            return profile([-24 if track_id else -18] * 80)
        self.session.measure = measure

    def analyze(self, tracks=None):
        return self.session.execute_tool('analyze_track_levels', {'tracks': tracks or ['vocal', 'guitar'], 'stage': 'verify'})

    def review(self, track, decision='already_consistent'):
        return self.session.execute_tool('review_level_balance', {
            'track': track, 'decision': decision, 'reason': 'Measured section levels remain consistent.'})

    def test_full_passage_batch_and_persisted_evidence(self):
        self.session.diagnostic_bounds = [110, 140]
        result = self.analyze()
        self.assertEqual(self.windows, [(None, [100, 180]), ('vocal', [100, 180]), ('guitar', [100, 180])])
        self.assertEqual(len(result['reports']), 2)
        self.assertEqual(len(worker.read(self.path / 'level-balance.json')), 2)
        self.review('vocal'); self.review('guitar')
        self.assertEqual(self.session.leveling_issues(), [])

    def test_measured_review_can_explain_several_rides_without_a_hidden_512_character_limit(self):
        self.analyze()
        reason = 'Measured phrase rides and section dynamics remain verified. ' * 20
        self.session.execute_tool('review_level_balance', {
            'track': 'vocal', 'decision': 'intentional_dynamics', 'reason': reason})
        self.assertEqual(self.session.level_reviews['vocal']['reason'], reason.strip())
        for invalid in ('x' * 2049, '', 'bad\x00reason'):
            with self.assertRaises(ValueError):
                self.session.execute_tool('review_level_balance', {
                    'track': 'vocal', 'decision': 'intentional_dynamics', 'reason': invalid})

    def test_requires_current_evidence_after_individual_and_batch_edits(self):
        with self.assertRaises(ValueError): self.review('vocal')
        self.analyze(); self.review('vocal'); self.review('guitar')
        self.session.execute_tool('set_track_mix', {'track': 'guitar', 'volume_db': -9, 'pan': 0})
        self.assertEqual(len(self.session.leveling_issues()), 2)
        with self.assertRaises(ValueError): self.review('vocal')
        self.analyze(); self.review('vocal'); self.review('guitar')
        self.session.execute_tool('apply_mix_batch', {'operations': [
            {'tool': 'set_track_mix', 'arguments': {'track': 'vocal', 'volume_db': -3, 'pan': 0}}]})
        with self.assertRaises(ValueError): self.review('guitar')

    def test_automation_requires_rides_then_reanalysis(self):
        self.analyze()
        with self.assertRaises(ValueError): self.review('vocal', 'automated')
        self.session.execute_tool('set_trim_automation', {'track': 'vocal', 'points': [
            {'seconds': 100, 'db': 0}, {'seconds': 140, 'db': 5}, {'seconds': 180, 'db': 0}]})
        with self.assertRaises(ValueError): self.review('vocal', 'automated')
        self.analyze(); self.review('vocal', 'automated')
        self.assertEqual(self.session.level_reviews['vocal']['decision'], 'automated')

    def test_partial_failed_evidence_is_not_called_balanced(self):
        measure = self.session.measure
        def failure(label, track_id=None, window=None):
            if track_id == 'vocal': raise ValueError('Muted contribution')
            return measure(label, track_id, window)
        self.session.measure = failure
        result = self.analyze()
        self.assertEqual(len(result['reports']), 1)
        self.assertEqual(len(result['errors']), 1)
        with self.assertRaises(ValueError): self.review('vocal')
        self.review('vocal', 'unmeasurable'); self.review('guitar')
        self.assertIn('could not be verified', self.session.leveling_issues()[0])

    def test_unknown_tracks_and_duplicate_ids_rejected_before_renders(self):
        for tracks in (['vocal', 'vocal'], ['MASTER'], ['missing']):
            with self.assertRaises(ValueError): self.analyze(tracks)
        self.assertEqual(self.windows, [])

    def test_agent_cannot_finish_on_loudness_alone(self):
        payloads = []
        def api(route, payload):
            payloads.append(copy.deepcopy(payload))
            if len(payloads) == 1:
                return {'choices': [{'message': {'role': 'assistant', 'content': 'LUFS is good, finished.'}}]}
            operations = [('analyze_track_levels', {'tracks': ['vocal', 'guitar']})] if len(payloads) == 2 else [
                ('review_level_balance', {'track': track, 'decision': 'intentional_dynamics',
                                         'reason': 'Full-passage evidence confirms the intentional level arrangement.'})
                for track in ['vocal', 'guitar']]
            return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                {'id': str(i), 'function': {'name': name, 'arguments': json.dumps(args)}}
                for i, (name, args) in enumerate(operations)]}}]}
        self.session.api = api
        with patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
            self.assertEqual(self.session.run(), 'review')
        self.assertEqual(len(payloads), 3)
        self.assertIn('level_balance_targets', json.loads(payloads[0]['messages'][1]['content']))
        # The startup chart pass now supplies the same full-passage evidence;
        # an unreviewed baseline still blocks completion, without rendering twice.
        initial = json.loads(payloads[0]['messages'][1]['content'])['instrument_baseline']
        self.assertEqual(len(initial['level_reports']), 2)
        self.assertIsNone(json.loads(payloads[1]['messages'][-1]['content'])['level_verification'])
        self.assertEqual(self.session.leveling_issues(), [])

    def test_exhausted_budget_reports_unverified_leveling(self):
        self.session.config['rounds'] = 1
        self.session.api = lambda *args: {'choices': [{'message': {'role': 'assistant', 'content': 'Finished.'}}]}
        with patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
            self.assertEqual(self.session.run(), 'review')
        state = worker.read(self.path / 'status.json')
        self.assertEqual(state['completion_reason'], 'level_balance_incomplete')
        self.assertEqual(len(state['level_balance']['remaining']), 2)
        self.assertTrue(any('remains unverified' in row['text'] for row in state['events']))


if __name__ == '__main__':
    unittest.main()
