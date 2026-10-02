"""Track identity, passage provenance, saved-render reuse and path boundaries."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import track_graphics as graphs
import worker
from test_visuals import write_wav, profile


class TrackGraphicsTests(unittest.TestCase):
    def test_graphs_keep_track_scope_bounds_and_do_not_replace_newer_capture(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp); path = folder/'render-1-test.wav'
            t = np.arange(48000*8)/48000
            write_wav(path, np.column_stack([.2*np.sin(t*2*np.pi*440)]*2))
            worker.write(folder/'snapshot.json', {'bounds': [100,108]})
            p = dict(profile(), track='{A}', scope=graphs.SCOPE)
            current = graphs.record(folder,path,p,'Guitar',measured_at=200,origin='Manual track capture')
            self.assertEqual(current['bounds'], [100,108])
            self.assertEqual(current['track'], '{A}')
            self.assertEqual(current['scope'], graphs.SCOPE)
            self.assertTrue(current['full_passage'])
            self.assertEqual(set(current['views']), {'spectrogram','waterfall','dynamics'})
            for name in current['views'].values(): self.assertTrue((folder/'visuals'/name).exists())
            graphs.record(folder,path,p,'Guitar',measured_at=100,origin='Saved AI measurement')
            self.assertEqual(worker.read(folder/'track-graphics.json')['tracks'][0]['origin'], 'Manual track capture')
            # Same-name tracks stay distinct and excerpts don't erase full passages.
            graphs.record(folder,path,dict(p,track='{B}'),'Guitar',measured_at=300)
            excerpt = dict(p,measurement_bounds=[102,110])
            graphs.record(folder,path,excerpt,'Guitar',measured_at=400)
            self.assertEqual(len(worker.read(folder/'track-graphics.json')['tracks']),3)

    def test_backfill_uses_latest_full_and_excerpt_with_names_no_daw_or_api(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);worker.write(folder/'snapshot.json',{'bounds':[0,10]})
            events=[{'kind':'bridge_response','tool':'inspect_project','response':{'result':{'tracks':[{'id':'{A}','name':'Vocals'}]}}}]
            for stamp,bounds in [(1,[0,10]),(2,[0,10]),(3,[2,5]),(4,[3,6])]:
                events.append({'kind':'measurement','track':'{A}','bounds':bounds,'time':stamp,'render':'render-%d-test.wav'%stamp})
            (folder/'events.jsonl').write_text('\n'.join(json.dumps(r) for r in events)+'\n{"partial')
            seen=[]
            def saved(directory,item): seen.append(item);return {'key':item['render']}
            with patch.object(graphs,'analyze_saved',side_effect=saved), \
                 patch.object(worker,'request',side_effect=AssertionError('No network')), \
                 patch.object(worker.Session,'bridge',side_effect=AssertionError('No DAW')):
                result=graphs.backfill(folder)
            self.assertEqual([r['render'] for r in seen],['render-2-test.wav','render-4-test.wav'])
            self.assertTrue(all(r['name']=='Vocals' for r in seen))
            self.assertEqual(result['errors'],[])

    def test_paths_and_invalid_audio_cannot_publish_false_success(self):
        with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryDirectory() as other:
            folder=Path(temp);outside=Path(other)/'render-1-test.wav';outside.write_bytes(b'audio')
            for name in ['../render-1-test.wav','credentials.json','/render-1-test.wav']:
                with self.assertRaises(ValueError):graphs.render_path(folder,name)
            (folder/outside.name).symlink_to(outside)
            with self.assertRaisesRegex(ValueError,'belong'):graphs.render_path(folder,outside.name)
            (folder/outside.name).unlink();path=folder/outside.name;path.write_bytes(b'audio')
            worker.write(folder/'snapshot.json',{'bounds':[100,108]})
            silent=dict(profile(),track='{A}',loudness={'integrated_lufs':None})
            with self.assertRaisesRegex(ValueError,'no measurable'):graphs.record(folder,path,silent,'Silent')
            with self.assertRaisesRegex(ValueError,'incomplete'):graphs.record(folder,path,dict(profile(),track='{A}',duration_seconds=2),'Partial')
            self.assertFalse((folder/'track-graphics.json').exists())

    def test_capture_job_does_not_overwrite_mix_state_or_start_worker(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);worker.write(folder/'status.json',{'state':'review','cost_usd':0.5})
            worker.write(folder/'track-graphics-request.json',{'render':'render-1-test.wav','track':'{A}'})
            with patch.object(graphs,'analyze_saved',return_value={'key':'{A}:full'}) as captured:
                self.assertEqual(graphs.run(folder,capture=True)['selected'],'{A}:full')
            self.assertEqual(captured.call_count,1)
            self.assertEqual(worker.read(folder/'status.json'),{'state':'review','cost_usd':0.5})
            self.assertFalse((folder/'request.json').exists())
            with patch.object(graphs,'analyze_saved',side_effect=ValueError('incomplete render')):
                with self.assertRaises(ValueError):graphs.run(folder,capture=True)
            self.assertEqual(worker.read(folder/'track-graphics-status.json')['state'],'error')


if __name__=='__main__':unittest.main()
