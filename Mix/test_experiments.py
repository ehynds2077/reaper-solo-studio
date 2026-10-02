"""Checkpoint comparisons restore the current sound on success, failure and cancel."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import worker


class ExperimentTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        worker.write(self.path / 'config.json', {'bounds': [10, 18], 'visual_analysis': False})
        self.session = worker.Session(self.path); self.session.diagnostic_bounds = [10, 18]
        self.session.visuals_enabled = True
        self.calls = []; self.current = 'starting'; self.fail = None
        self.profile = {'duration_seconds': 8, 'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2},
                        'envelope_1s': [{'seconds': n, 'rms_dbfs': -18, 'crest_db': 9} for n in range(8)]}
        def bridge(name, args):
            self.calls.append((name, copy.deepcopy(args), getattr(self.session, 'checkpoint_cleanup', False)))
            self.session.calls += 1
            if name == 'list_mix_checkpoints':
                return {'checkpoints': [{'id': 'a', 'name': 'A'}, {'id': 'b', 'name': 'B'}]}
            if name == 'save_mix_checkpoint': return {'id': 'return'}
            if name == 'restore_mix_checkpoint':
                if self.fail == 'restore' and args['id'] == 'return': return {'error': 'Outside edit'}
                self.current = args['id']; return {'restored': self.current}
            if name == 'measure_mix':
                if self.fail == 'render': return {'error': 'No audio'}
                if self.fail == 'cancel':
                    (self.path / 'cancel').touch(); raise RuntimeError('Session cancelled')
                return {'path': str(self.path / (self.current + '.wav')), 'bounds': [10, 18]}
            return {'ok': True}
        self.session.bridge = bridge

    def compare(self):
        return self.session.execute_tool('compare_mix_checkpoints', {'ids': ['a', 'b']})

    def test_comparison_matches_loudness_and_restores_candidate_before_charting(self):
        import charts  # Load before mocking ffmpeg's subprocess module.
        quiet = copy.deepcopy(self.profile); quiet['loudness']['integrated_lufs'] = -17
        with patch.object(worker, 'analyze_audio', side_effect=[self.profile, quiet]), patch('experiments.subprocess.run') as ffmpeg:
            result = self.compare()
        self.assertEqual(self.current, 'return')
        self.assertTrue(result['candidate_restored'])
        self.assertEqual(result['matched_lufs'], -17)
        self.assertEqual([r['display_gain_db'] for r in result['experiments']], [-3, 0])
        self.assertEqual(ffmpeg.call_count, 2)
        self.assertEqual(len(self.session.pending_images), 1)
        self.assertEqual(self.session.pending_images[0][0].parent, (self.path / 'visuals').resolve())
        self.assertTrue((self.path / result['chart']).is_file())
        self.assertEqual(self.calls[-2][0:2], ('restore_mix_checkpoint', {'id': 'return'}))
        self.assertTrue(self.calls[-2][2])
        self.assertFalse(self.session.checkpoint_cleanup)

    def test_render_failure_restores_original_candidate(self):
        self.fail = 'render'
        with self.assertRaisesRegex(ValueError, 'No audio'): self.compare()
        self.assertEqual(self.current, 'return')
        self.assertEqual(self.calls[-1][0], 'delete_mix_checkpoint')

    def test_cancel_keeps_cleanup_enabled_until_candidate_restored(self):
        self.fail = 'cancel'
        with self.assertRaisesRegex(RuntimeError, 'cancelled'): self.compare()
        self.assertEqual(self.current, 'return')
        self.assertTrue(self.calls[-2][2] and self.calls[-1][2])
        self.assertFalse(self.session.checkpoint_cleanup)

    def test_failed_restore_retains_named_recovery_checkpoint(self):
        self.fail = 'restore'
        with patch.object(worker, 'analyze_audio', return_value=self.profile):
            with self.assertRaisesRegex(RuntimeError, 'checkpoint return'): self.compare()
        self.assertNotIn('delete_mix_checkpoint', [c[0] for c in self.calls])
        self.assertFalse(self.session.checkpoint_cleanup)

    def test_bad_ids_and_budget_rejected_before_mix_changes(self):
        for ids in (['a', 'a'], ['a', 'missing'], ['a']):
            with self.assertRaises(ValueError): self.session.execute_tool('compare_mix_checkpoints', {'ids': ids})
        self.session.calls = worker.MAX_BRIDGE_CALLS - 3
        with self.assertRaisesRegex(ValueError, 'budget'): self.compare()
        self.assertNotIn('save_mix_checkpoint', [c[0] for c in self.calls])

    def test_unmeasurable_experiment_restores_current_candidate(self):
        invalid = copy.deepcopy(self.profile); invalid['loudness']['integrated_lufs'] = None
        with patch.object(worker, 'analyze_audio', return_value=invalid):
            with self.assertRaisesRegex(ValueError, 'no measurable audio'): self.compare()
        self.assertEqual(self.current, 'return')

    def test_new_controls_batch_and_invalidate_old_level_evidence(self):
        operations = [
            {'tool': 'set_master_output', 'arguments': {'volume_db': -3}},
            {'tool': 'move_effect', 'arguments': {'track': 'guitar', 'effect': 'eq', 'index': 0}},
            {'tool': 'set_send', 'arguments': {'track': 'guitar', 'destination': 'room', 'volume_db': -18}},
            {'tool': 'set_pre_fx_automation', 'arguments': {'track': 'guitar', 'points': [
                {'seconds': 10, 'db': 0}, {'seconds': 12, 'db': -3}, {'seconds': 18, 'db': 0}]}}]
        result = self.session.execute_tool('apply_mix_batch', {'operations': operations})
        self.assertEqual(result['completed'], 4)
        self.assertEqual(self.session.global_edit_revision, self.session.mix_revision)
        self.assertEqual(self.session.mix_revision, 4)

    def test_master_processors_batch_and_invalidate_level_evidence(self):
        operations = [
            {'tool': 'configure_tape', 'arguments': {'track': 'MASTER', 'effect': 'tape',
                'preset': 'Clean Ultralinear Master'}},
            {'tool': 'configure_tape', 'arguments': {'track': 'MASTER', 'effect': 'tape',
                'input_db': -6, 'output_db': 6}},
            {'tool': 'configure_bus_compressor', 'arguments': {'track': 'MASTER',
                'effect': 'ssl', 'threshold_db': -4, 'attack_ms': 30, 'release': 'auto'}},
            {'tool': 'configure_clipper', 'arguments': {'track': 'MASTER',
                'effect': 'clip', 'clipping_db': -2, 'oversampling': '192k'}},
            {'tool': 'move_effect', 'arguments': {'track': 'MASTER', 'effect': 'clip', 'index': 2}}]
        result = self.session.execute_tool('apply_mix_batch', {'operations': operations})
        self.assertEqual(result['completed'], 5)
        self.assertEqual([c[0] for c in self.calls], [op['tool'] for op in operations])
        self.assertEqual(self.session.global_edit_revision, 5)

    def test_invalid_processor_batch_rejected_before_any_writes(self):
        for tool, args in (
            ('configure_tape', {'input_db': 20}),
            ('configure_tape', {'preset': 'invented preset'}),
            ('configure_bus_compressor', {'threshold_db': -4, 'attack_ms': 20}),
            ('configure_clipper', {'clipping_db': -2, 'oversampling': '16x'})):
            with self.subTest(tool=tool, args=args), self.assertRaises(ValueError):
                self.session.execute_tool('apply_mix_batch', {'operations': [
                    {'tool': 'set_master_output', 'arguments': {'volume_db': -3}},
                    {'tool': tool, 'arguments': {'track': 'MASTER', 'effect': 'fx', **args}}]})
        self.assertEqual(self.calls, [])

    def test_checkpoint_bypassed_rides_are_reactivated_not_skipped_as_unchanged(self):
        rides = [{'start_seconds': 12, 'end_seconds': 15, 'gain_db': -3}]
        points = worker.planning.phrase_envelope([], rides, [10, 18])
        self.session.project = {'trim_envelopes': [{'track': 'guitar', 'points': points, 'enabled': False}]}
        bridge = self.session.bridge
        self.session.bridge = lambda name, args: self.session.project if name == 'inspect_project' else bridge(name, args)
        result = self.session.execute_tool('set_phrase_rides', {'track': 'guitar', 'rides': rides})
        self.assertFalse(result.get('unchanged', False))
        self.assertEqual(self.calls[-1][0], 'set_trim_automation')
        self.assertTrue(self.session.project['trim_envelopes'][0]['enabled'])
        self.assertTrue(self.session.trim_changes['guitar'])
        self.session.mix_edit('restore_mix_checkpoint', {'id': 'a'})
        self.assertFalse(self.session.trim_edits)
        self.assertFalse(self.session.trim_changes)


if __name__ == '__main__': unittest.main()
