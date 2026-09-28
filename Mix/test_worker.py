import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import worker


class WorkerTests(unittest.TestCase):
    def test_argument_validation(self):
        specs = {t['function']['name']: t['function']['parameters'] for t in worker.TOOLS}
        worker.validate({'track': 'guid', 'volume_db': -3, 'pan': .2}, specs['set_track_mix'])
        for args in ({'track':'g','volume_db':float('nan'),'pan':0},
                     {'track':'g','volume_db':3,'pan':2},
                     {'track':'g','volume_db':3,'pan':False},
                     {'track':'g','volume_db':3,'pan':0,'shell':'rm'}, {}):
            with self.assertRaises(ValueError):
                worker.validate(args, specs['set_track_mix'])

    def test_private_storage(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'credential.json'
            worker.write(path, {'api_key':'synthetic-test-value'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(worker.read(path)['api_key'], 'synthetic-test-value')

    def test_compact_profile_has_no_paths_hashes_or_long_timelines(self):
        result = worker.compact({'title':'test','source_name':'private.wav', 'source_sha256':'secret',
            'loudness':{'integrated_lufs':-18,'timeline':[1]*100},
            'envelope_1s':[{'seconds':i} for i in range(1000)]})
        self.assertNotIn('source_name', result)
        self.assertNotIn('source_sha256', result)
        self.assertNotIn('timeline', result['loudness'])
        self.assertLessEqual(len(result['envelope_1s']), 90)

    def test_actual_file_bridge_and_cancel(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json', {})
            session=worker.Session(path)
            def reaper():
                while not (path/'request.json').exists():
                    time.sleep(.01)
                req=worker.read(path/'request.json')
                worker.write(path/('response-'+req['id']+'.json'), {'result':{'ok':True}})
            thread=threading.Thread(target=reaper);thread.start()
            self.assertEqual(session.bridge('inspect_project', {}), {'ok':True})
            thread.join()
            (path/'cancel').touch()
            with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                session.bridge('inspect_project', {})

    def test_partial_render_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json', {'bounds':[0,8]})
            session=worker.Session(path)
            session.bridge=lambda *a: {'path':str(path/'render-1.wav')}
            with patch.object(worker,'analyze_audio',return_value={'duration_seconds':2}):
                with self.assertRaisesRegex(RuntimeError,'incomplete'):
                    session.measure('Candidate')
            self.assertEqual(session.measurements,[])

    def test_tool_loop_bad_tool_readbacks_and_final_render(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json', {'bounds':[0,8], 'rounds':3})
            requests=[];executed=[]
            def api(route, payload):
                requests.append(payload)
                if len(requests)==1:
                    return {'choices':[{'message':{'role':'assistant','content':'I will lower the guitar.',
                        'tool_calls':[
                            {'id':'bad','function':{'name':'execute_shell','arguments':'{}'}},
                            {'id':'good','function':{'name':'set_track_mix','arguments':json.dumps({'track':'g','volume_db':-3,'pan':.2})}}
                        ]}}]}
                return {'choices':[{'message':{'role':'assistant','content':'Ready for review.'}}], 'usage':{'cost':.01}}
            session=worker.Session(path, api)
            session.bridge=lambda name,args: executed.append((name,args)) or {'tracks':[]}
            def measure(label, track_id=None):
                profile={'title':label,'loudness':{'integrated_lufs':-18,'true_peak_dbtp':-3}}
                session.measurements.append(profile)
                return profile
            session.measure=measure
            with patch.object(worker,'library',return_value={'references':[]}):
                self.assertEqual(session.run(), 'review')
            self.assertEqual([e[0] for e in executed], ['inspect_project','set_track_mix'])
            self.assertEqual(len(session.measurements),2)
            self.assertIn('Unknown tool', requests[1]['messages'][3]['content'])
            self.assertEqual(len(requests[1]['tools']),len(worker.TOOLS))
            self.assertEqual(worker.read(path/'status.json')['state'],'review')

    def test_peak_warning_and_provider_failure(self):
        for peak, should_fail in [(0.2,False),(-3,True)]:
            with tempfile.TemporaryDirectory() as temp:
                path=Path(temp);worker.write(path/'config.json',{'bounds':[0,8]})
                def api(*args):
                    if should_fail:
                        raise RuntimeError('API key was rejected (HTTP 401)')
                    return {'choices':[{'message':{'role':'assistant','content':'Done'}}]}
                session=worker.Session(path,api)
                session.bridge=lambda *a: {}
                session.measure=lambda *a: {'loudness':{'integrated_lufs':-14,'true_peak_dbtp':peak}}
                with patch.object(worker,'library',return_value={'references':[]}):
                    self.assertEqual(session.run(), 'error' if should_fail else 'review_warning')


if __name__=='__main__':
    unittest.main()
