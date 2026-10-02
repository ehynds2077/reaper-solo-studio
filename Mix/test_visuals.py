"""Measured image accuracy and multimodal protocol checks; no paid requests."""
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import numpy as np
import worker
import visuals
import planning


def write_wav(path, samples, width=3):
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(samples.shape[1]); file.setsampwidth(width); file.setframerate(48000)
        if width == 3:
            ints = np.round(samples * 8388607).astype(np.int32).reshape(-1)
            data = np.column_stack([ints & 255, (ints >> 8) & 255, (ints >> 16) & 255]).astype(np.uint8)
            file.writeframes(data.tobytes())
        else:
            file.writeframes(np.round(samples * (2 ** (width * 8 - 1) - 1)).astype('<i%d' % width).tobytes())


def profile():
    return {'title': 'Synthetic measured output', 'duration_seconds': 8,
            'measurement_bounds': [100, 108], 'measurement_kind': 'full_passage',
            'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2, 'loudness_range_lu': 3},
            'crest_db': 9, 'envelope_1s': [{'seconds': n, 'rms_dbfs': -18, 'peak_dbfs': -6} for n in range(8)],
            'bands': [{'low_hz': 20, 'high_hz': 20000, 'relative_db': 0, 'side_fraction': .2}],
            'spectrum': [{'low_hz': 20, 'high_hz': 20000, 'relative_db': 0}]}


class VisualTests(unittest.TestCase):
    def test_waveform_retains_single_sample_peaks_and_stereo_antiphase(self):
        for width in (2, 3, 4):
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp)/'source.wav'; data = np.zeros((48000, 2))
                data[23451] = [.75, -.75]; data[-1] = [-.9, .9]
                write_wav(path, data, width)
                x, low, high = visuals.waveform(path, bins=100)
                self.assertEqual(len(x), 100)
                self.assertAlmostEqual(high.max(), .9, places=4)
                self.assertAlmostEqual(low.min(), -.9, places=4)
                self.assertAlmostEqual(high[48], .75, places=4)

    def test_processed_and_source_charts_are_bounded_pngs(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); source = folder/'source.wav'
            write_wav(source, np.zeros((48000 * 8, 2)))
            outputs = [folder/'processed.png', folder/'source.png']
            visuals.processed_chart(source, profile(), [], [{'start_seconds': 103, 'name': 'Chorus $test$'}], outputs[0])
            row = {'name': 'Guitar', 'muted': False, 'peaks': [0, .5, 0, .2],
                   'clips': [{'start_seconds': 100, 'end_seconds': 108, 'kind': 'peaks_unavailable'}],
                   'unavailable': 1, 'midi': 0, 'truncated': False}
            visuals.arrangement_chart({'tracks': [row], 'bounds': [100, 108], 'start_track': 0,
                                       'total_tracks': 1, 'truncated': False}, outputs[1])
            plan = planning.level_curve(profile(), [], [100, 108])
            outputs.append(folder / 'level-curve.png')
            visuals.level_curve_chart(plan, outputs[-1])
            for output in outputs:
                self.assertTrue(output.read_bytes().startswith(b'\x89PNG'))
                self.assertLess(output.stat().st_size, 500000)
            self.assertEqual(len(visuals.plt.get_fignums()), 0)

    def test_capability_lookup_handles_image_models_text_models_and_offline(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(worker, 'DATA', Path(temp)):
            for modalities, expected in [(['text', 'image'], True), (['text'], False)]:
                response = io.BytesIO(json.dumps({'data': {'architecture': {'input_modalities': modalities}}}).encode())
                with patch.object(worker.urllib.request, 'urlopen', return_value=response) as get:
                    self.assertIs(worker.image_support('vendor/test'), expected)
                    self.assertEqual(get.call_args[0][0], worker.API + '/models/vendor/test/endpoints')
            with patch.object(worker.urllib.request, 'urlopen', side_effect=OSError('offline')):
                self.assertIsNone(worker.image_support('vendor/test'))

    def test_visual_messages_follow_tool_replies_and_old_images_are_pruned(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); worker.write(folder/'config.json', {'bounds': [0, 8]})
            images = folder/'visuals'; images.mkdir()
            session = worker.Session(folder)
            messages = [{'role': 'assistant', 'tool_calls': [{'id': 'a'}, {'id': 'b'}]},
                        {'role': 'tool', 'tool_call_id': 'a', 'content': '{}'},
                        {'role': 'tool', 'tool_call_id': 'b', 'content': '{}'}]
            for n in range(7):
                image = images/('%d.png' % n); image.write_bytes(b'\x89PNG\r\n\x1a\nsynthetic')
                session.queue_image(image, 'Measured chart %d' % n); session.attach_images(messages)
            self.assertEqual(messages[2]['tool_call_id'], 'b')
            self.assertEqual(messages[3]['role'], 'user')
            images_in_context = [part for msg in messages if isinstance(msg.get('content'), list)
                                 for part in msg['content'] if part['type'] == 'image_url']
            self.assertEqual(len(images_in_context), 4)
            self.assertTrue(all(p['image_url']['url'].startswith('data:image/png;base64,') for p in images_in_context))
            self.assertNotIn(temp, json.dumps(messages))
            with self.assertRaises(ValueError): session.queue_image(folder/'private.png', 'No')
            missing = images/'gone.png'; session.queue_image(missing, 'Missing'); session.attach_images(messages)
            self.assertEqual(session.visual_status['attached'], 7)

    def test_images_use_existing_measurement_and_do_not_add_renders(self):
        for supported, enabled in [(True, True), (False, True), (None, True), (True, False)]:
            with tempfile.TemporaryDirectory() as temp:
                folder = Path(temp); worker.write(folder/'config.json', {'bounds': [100, 108], 'rounds': 2,
                                                                       'visual_analysis': enabled})
                source = folder/'render.wav'; write_wav(source, np.zeros((48000 * 8, 2)))
                calls = []; requests = []
                def api(route, payload):
                    requests.append(copy.deepcopy(payload))
                    if len(requests) == 1:
                        return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                            {'id': 'a', 'function': {'name': 'measure_mix', 'arguments': '{}'}},
                            {'id': 'b', 'function': {'name': 'inspect_project', 'arguments': '{}'}}]}}]}
                    return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured summary.'}}]}
                session = worker.Session(folder, api)
                def bridge(name, args):
                    calls.append(name)
                    if name == 'inspect_project': return {'tracks': [], 'capabilities': {'mix_tools_version': 3}}
                    return {'path': str(source), 'cached': calls.count('measure_mix') > 1}
                session.bridge = bridge
                with patch.object(worker, 'image_support', return_value=supported), \
                     patch.object(worker, 'analyze_audio', side_effect=lambda *a: profile()), \
                     patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
                    self.assertEqual(session.run(), 'review')
                self.assertEqual(calls.count('measure_mix'), 4)  # Original, model, completion, final; no image-only renders.
                has_images = any(isinstance(m.get('content'), list) for m in requests[-1]['messages'])
                self.assertEqual(has_images, supported is True and enabled)
                messages = requests[-1]['messages']
                tool_positions = [i for i, m in enumerate(messages) if m['role'] == 'tool']
                if has_images:
                    self.assertEqual(messages[max(tool_positions)+1]['role'], 'user')
                    self.assertEqual(len(list((folder/'visuals').glob('*.png'))), 1)
                self.assertNotIn('data:image', (folder/'status.json').read_text())


if __name__ == '__main__':
    unittest.main()
