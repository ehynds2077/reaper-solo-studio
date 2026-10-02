"""Startup coverage, first-turn image delivery and reuse without model/API edits."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import track_graphics
import worker


class InstrumentInventoryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        worker.write(self.folder / 'config.json', {'bounds': [100, 108], 'rounds': 2})
        (self.folder / 'visuals').mkdir()
        self.session = worker.Session(self.folder)
        self.tracks = [{'id': 'track-%d' % i, 'name': 'Guitar' if i < 2 else 'Source %d' % i,
                        'items': 1, 'playing_items_in_passage': 1} for i in range(10)]
        self.project = {'tracks': self.tracks, 'capabilities': {'mix_tools_version': 4}}
        self.session.project = self.project
        self.calls = []; self.requests = []
        self.session.bridge = self.bridge
        self.session.measure = self.measure
        self.profile = {'duration_seconds': 8, 'measurement_bounds': [100, 108],
                        'loudness': {'integrated_lufs': -12, 'true_peak_dbtp': -2},
                        'envelope_1s': [{'seconds': i, 'rms_dbfs': -24, 'peak_dbfs': -12} for i in range(8)]}

    def bridge(self, name, args):
        self.calls.append((name, args))
        self.assertEqual(name, 'inspect_project')  # Inventory must never edit.
        return self.project

    def measure(self, label, track_id=None, window=None):
        self.calls.append(('measure', track_id, window))
        profile = copy.deepcopy(self.profile)
        if track_id:
            path = self.folder / 'visuals' / (track_id + '.png')
            Image.new('RGB', (1320, 693), 'white').save(path)
            self.session.track_graphs[track_id] = {'track': track_id, 'name': 'Source ' + track_id,
                'bounds': [100, 108], 'scope': track_graphics.SCOPE, 'views': {'spectrogram': path.name}}
            profile.update(track=track_id, scope=track_graphics.SCOPE)
        return profile

    def test_selects_every_source_with_duplicate_names_and_no_inventory_cap(self):
        tracks = [dict(self.tracks[0], id='t%d' % i) for i in range(35)]
        tracks += [
            {'id': 'bus', 'name': 'Folder', 'items': 0},
            {'id': 'child', 'parent': 'bus', 'items': 1},
            {'id': 'muted', 'items': 1, 'muted': True},
            {'id': 'hidden', 'items': 1, 'parent': 'muted'},
            {'id': 'outside', 'items': 2, 'playing_items_in_passage': 0},
            {'id': 'zero', 'items': 1, 'fader_silent': True},
            {'id': 'automated', 'items': 1, 'fader_silent': True, 'volume_automated': True},
            {'id': 'sent', 'items': 1, 'fader_silent': True, 'sends': [{'destination': 'bus'}]},
            {'id': 'cyclic', 'items': 1, 'parent': 'cyclic'}]
        selected, skipped = track_graphics.instrument_tracks({'tracks': tracks})
        self.assertEqual(len(selected), 39)
        self.assertEqual({r['track'] for r in skipped}, {'bus', 'muted', 'hidden', 'outside', 'zero'})

    def test_all_charts_reach_first_model_turn_then_context_is_bounded(self):
        def api(route, payload):
            measured = [c[1] for c in self.calls if c[0] == 'measure' and c[1]]
            self.assertEqual(measured, [r['id'] for r in self.tracks])
            self.requests.append(copy.deepcopy(payload))
            if len(self.requests) == 1:
                return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                    {'id': 'inspect', 'function': {'name': 'inspect_project', 'arguments': '{}'}}]}}]}
            return {'choices': [{'message': {'role': 'assistant', 'content': 'Review complete.'}}]}
        self.session.api = api
        with patch.object(worker, 'image_support', return_value=True), \
             patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
            self.session.run()
        self.assertEqual(len(self.requests), 2)
        images = lambda request: [part for m in request['messages'] if isinstance(m.get('content'), list)
                                  for part in m['content'] if part['type'] == 'image_url']
        self.assertEqual(len(images(self.requests[0])), 5)
        self.assertEqual(len(images(self.requests[1])), 4)
        baseline = json.loads(self.requests[0]['messages'][1]['content'])['instrument_baseline']
        self.assertEqual(baseline['completed'], 10)
        self.assertEqual(len(baseline['profiles']), 10)
        self.assertTrue(all(c[2] == [100, 108] for c in self.calls if c[0] == 'measure' and c[1]))
        # Two panels retain their original pixels and readable axes.
        with Image.open(next((self.folder / 'visuals').glob('instrument-start-*.png'))) as sheet:
            self.assertEqual(sheet.size, (1320, 1386))
        before = len(self.calls)
        self.session.analyze_track_levels(['track-0', 'track-1'])
        self.assertEqual(self.calls[before:], [('inspect_project', {})])
        self.assertNotIn('data:image', (self.folder / 'status.json').read_text())

    def test_no_vision_still_measures_sources_and_reports_individual_failures(self):
        def measure(label, track_id=None, window=None):
            if track_id == 'track-0': raise ValueError('No measurable audio')
            return self.measure(label, track_id, window)
        self.session.measure = measure
        result = self.session.prepare_instrument_charts(self.profile)
        self.assertEqual(result['state'], 'ready_with_errors')
        self.assertEqual((result['total'], result['completed']), (10, 9))
        self.assertEqual(result['errors'][0]['track'], 'track-0')
        self.assertEqual(self.session.pending_images, [])
        self.assertEqual(len(worker.read(self.folder / 'instrument-baseline.json')['profiles']), 9)

    def test_cancel_and_fatal_render_stop_before_remaining_sources(self):
        for cancelled in (True, False):
            calls = []
            def measure(label, track_id=None, window=None):
                calls.append(track_id)
                if cancelled:
                    (self.folder / 'cancel').touch()
                    return self.measure(label, track_id, window)
                raise RuntimeError('Incomplete render')
            self.session.measure = measure
            with self.assertRaisesRegex(RuntimeError, 'cancelled' if cancelled else 'Incomplete'):
                self.session.prepare_instrument_charts(self.profile)
            self.assertEqual(calls, ['track-0'])
            (self.folder / 'cancel').unlink(missing_ok=True)

    def test_continuation_refreshes_current_baseline_and_opt_out_is_explicit(self):
        for enabled in (True, False):
            worker.write(self.folder / 'config.json', {'bounds': [100, 108], 'rounds': 1,
                'resume': True, 'instrument_charts': enabled, 'visual_analysis': False})
            worker.write(self.folder / 'instrument-baseline.json', {'profiles': ['stale']})
            self.session = worker.Session(self.folder)
            self.session.bridge = self.bridge; self.session.measure = self.measure
            self.calls.clear()
            def api(*args):
                measured = [c[1] for c in self.calls if c[0] == 'measure' and c[1]]
                self.assertEqual(len(measured), 10 if enabled else 0)
                return {'choices': [{'message': {'role': 'assistant', 'content': 'Done.'}}]}
            self.session.api = api
            with patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
                self.session.run()
            self.assertEqual(self.session.state, 'review')
            if enabled:
                self.assertEqual(len(worker.read(self.folder / 'instrument-baseline.json')['profiles']), 10)


if __name__ == '__main__': unittest.main()
