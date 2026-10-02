"""Matched scales, source identity and review requests with no editing capability."""
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import reference_graphics as graphs
import worker
from test_visuals import profile, write_wav


class ReferenceGraphicsTests(unittest.TestCase):
    def test_float_reference_above_full_scale_is_not_clipped_and_cache_is_reused(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder / 'floating.wav'
            t = np.arange(48000 * 2) / 48000
            mono = 1.3 * np.sin(2 * np.pi * 1000 * t)
            pcm = np.column_stack((mono, -mono)).astype('<f4').tobytes()
            fmt = struct.pack('<HHIIHH', 3, 2, 48000, 48000 * 8, 8, 32)
            source.write_bytes(b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' +
                               struct.pack('<I', 16) + fmt + b'data' + struct.pack('<I', len(pcm)) + pcm)
            ref = dict(profile(), channels=2, duration_seconds=2, sample_peak_dbfs=20*np.log10(1.3),
                       source_sha256=graphs.source_digest(source))
            worker.write(folder / 'profile.json', ref)
            row = {'id': 'ref', 'title': 'Reference', 'profile': str(folder / 'profile.json'), 'source_path': str(source)}
            p, data, views, stem = graphs.reference_data(row, folder)
            measured = 10*np.log10((10**(data['dbfs'][:, 10]/10)).sum())
            self.assertAlmostEqual(measured, 10*np.log10(1.3**2/2), places=2)
            self.assertEqual(p['measurement_bounds'], [0, 2])
            for name in views.values(): self.assertTrue((folder / name).read_bytes().startswith(b'\x89PNG'))
            with patch.object(graphs.subprocess, 'run', side_effect=AssertionError('Cached spectrum avoids decoding')):
                again = graphs.reference_data(row, folder)
                np.testing.assert_array_equal(again[1]['dbfs'], data['dbfs'])
            source.write_bytes(source.read_bytes() + b'changed')
            with self.assertRaisesRegex(ValueError, 'changed'): graphs.reference_data(row, folder)

    def test_source_link_requires_exact_hash_and_does_not_relabel_reference(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder/'ref.wav'; source.write_bytes(b'original')
            worker.write(folder/'profile.json', {'source_sha256': graphs.source_digest(source), 'channels': 2})
            worker.write(folder/'library.json', {'references': [{'id': 'ref', 'title': 'Keep title', 'profile': str(folder/'profile.json')} ]})
            with patch.object(worker, 'DATA', folder):
                graphs.link_source('ref', source)
                self.assertEqual(worker.library()['references'][0]['title'], 'Keep title')
                self.assertEqual(worker.library()['references'][0]['source_path'], str(source.resolve()))
                source.write_bytes(b'different')
                before = (folder/'library.json').read_bytes()
                with self.assertRaisesRegex(ValueError, 'does not match'): graphs.link_source('ref', source)
                self.assertEqual((folder/'library.json').read_bytes(), before)

    def test_comparison_only_changes_display_gain_and_keeps_separate_timelines(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)/'compare.png'
            mix = profile(); ref = copy.deepcopy(mix); ref.update(title='Reference', measurement_bounds=[0, 4])
            mix['loudness']['integrated_lufs'] = -12; ref['loudness']['integrated_lufs'] = -8.9
            data = {'time_edges': np.array([0, 1, 2]), 'frequency_edges': np.array([30, 300, 3000, 20000]),
                    'dbfs': np.full((3, 2), -30.)}
            original = data['dbfs'].copy()
            self.assertAlmostEqual(graphs.comparison_chart(data, data, mix, ref, output), -3.1)
            np.testing.assert_array_equal(original, data['dbfs'])
            self.assertEqual(ref['loudness']['integrated_lufs'], -8.9)
            self.assertTrue(output.exists())

    def test_ai_review_has_images_but_no_tools_paths_or_project_mutations(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); images = folder/'visuals'; images.mkdir()
            for name in ['compare.png', 'mix.png', 'ref.png']:
                (images/name).write_bytes(b'\x89PNG\r\n\x1a\nfixture')
            worker.write(folder/'config.json', {'model': 'test/vision', 'target_lufs': -12})
            worker.write(folder/'graphics.json', {'views': {'dynamics': 'mix.png'}})
            worker.write(folder/'snapshot.json', {'candidate': 'untouched'})
            bundle = {'render': 'render-1-test.wav', 'mix': profile(), 'mix_views': {'dynamics': 'mix.png'}, 'references': [
                {'title': 'Reference', 'display_gain_db': -3.1, 'comparison': 'compare.png',
                 'views': {'dynamics': 'ref.png'}, 'profile': profile()}]}
            requests = []
            def api(route, payload):
                requests.append(payload)
                return {'choices': [{'message': {'content': 'Measured comparison; listen to confirm.'}}], 'usage': {'cost': .01}}
            with patch.object(graphs, 'build', return_value=bundle), patch.object(worker, 'image_support', return_value=True), \
                 patch.object(worker.Session, 'bridge', side_effect=AssertionError('No DAW access')):
                result = graphs.review(folder, api)
            self.assertEqual(len(requests), 1)
            self.assertNotIn('tools', requests[0])
            self.assertNotIn(temp, json.dumps(requests))
            self.assertEqual(sum(p['type']=='image_url' for p in requests[0]['messages'][1]['content']), 3)
            self.assertTrue(result['read_only'])
            self.assertEqual(worker.read(folder/'snapshot.json'), {'candidate': 'untouched'})
            self.assertFalse((folder/'request.json').exists())


if __name__ == '__main__': unittest.main()
