import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import worker

PROJECT = {'tracks': [], 'capabilities': {'mix_tools_version': 3}}


class WorkerTests(unittest.TestCase):
    def setUp(self):
        # Ordinary protocol tests never look up model capabilities on the network.
        support = patch.object(worker, 'image_support', return_value=False)
        support.start(); self.addCleanup(support.stop)
        # Protocol fixtures contain partial profiles; chart rendering has its own
        # suite. Avoid leaving partial matplotlib figures in a combined test run.
        charts = patch('charts.render_charts')
        charts.start(); self.addCleanup(charts.stop)

    def test_diagnostic_window_uses_energy_and_absolute_project_time(self):
        profile = {'envelope_1s': [
            {'seconds': i, 'rms_dbfs': -12 if 60 <= i < 90 else None}
            for i in range(180)]}
        self.assertEqual(worker.diagnostic_bounds(profile, [100, 280]), [160, 190])
        self.assertEqual(worker.diagnostic_bounds(profile, [100, 130]), [100, 130])
        self.assertEqual(worker.diagnostic_bounds({}, [100, 280]), [100, 130])

    def test_window_requests_validate_scope_and_boolean(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp); worker.write(path/'config.json', {'bounds': [100, 280]})
            session = worker.Session(path); session.diagnostic_bounds = [160, 190]
            self.assertEqual(session.measurement_window({}), [160, 190])
            self.assertEqual(session.measurement_window({'full_passage': True}), [100, 280])
            self.assertEqual(session.measurement_window({'full_passage': True, 'start_seconds': 0, 'duration_seconds': 600}), [100, 280])
            self.assertEqual(session.measurement_window({'full_passage': True, 'start_seconds': 0}), [100, 280])
            self.assertEqual(session.measurement_window({'start_seconds': 200, 'duration_seconds': 30}), [200, 230])
            for args in ({'start_seconds': 100}, {'duration_seconds': 30},
                         {'start_seconds': 80, 'duration_seconds': 30},
                         {'start_seconds': 270, 'duration_seconds': 30}):
                with self.assertRaises(ValueError): session.measurement_window(args)
            spec = next(t['function']['parameters'] for t in worker.TOOLS if t['function']['name'] == 'measure_mix')
            for value in ('false', 1, None):
                with self.assertRaises(ValueError): worker.validate({'full_passage': value}, spec)
            for value in (True, float('inf'), -1):
                with self.assertRaises(ValueError):
                    session.execute_tool('measure_mix', {'full_passage': True, 'start_seconds': value})

    def test_conflicting_full_range_calls_do_not_pause_the_model_loop(self):
        request = {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
            {'id': 'mixed', 'function': {'name': 'measure_mix', 'arguments': json.dumps({
                'full_passage': True, 'start_seconds': 0, 'duration_seconds': 600})}}]}}]}
        done = {'choices': [{'message': {'role': 'assistant', 'content': 'Measured summary.'}}]}
        session, state, requests, _ = self.run_scripted_responses([request] * 3 + [done],
            {'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}})
        self.assertEqual(len(requests), 4)
        self.assertEqual((state, session.completion_reason), ('review', 'measured_completion'))
        self.assertEqual(len(session.measurements), 6)  # Original + 3 requests + completion + final.

    def test_rejected_requests_log_parsed_known_arguments_without_crashing(self):
        for arguments in ('{"start_seconds":0}', '{"start_seconds":1e999}', '{bad json',
                          '{"start_seconds":0,"unknown_secret_field":"do-not-log"}'):
            bad = {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                {'id': 'bad', 'function': {'name': 'measure_mix', 'arguments': arguments}}]}}]}
            with patch.object(worker.Session, 'trace', autospec=True) as trace:
                session, state, _, _ = self.run_scripted_responses([bad],
                    {'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}}, rounds=3)
            self.assertEqual((state, session.completion_reason), ('review', 'repeated_tool_errors'))
            rejected = [call.kwargs for call in trace.call_args_list if call.args[1] == 'tool_rejected']
            self.assertEqual(len(rejected), 3)
            encoded = json.dumps(rejected, allow_nan=False)
            self.assertNotIn('do-not-log', encoded)
            self.assertEqual(rejected[0]['tool'], 'measure_mix')
            self.assertIn('arguments', rejected[0])

    def test_cached_analysis_needs_native_confirmation_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp); worker.write(path/'config.json', {'bounds': [0, 180]})
            session = worker.Session(path); calls = []
            def bridge(name, args):
                calls.append((name, args))
                return {'path': str(path/'unique.wav'), 'cached': len(calls) == 2}
            session.bridge = bridge
            profile = {'title': 'Original', 'duration_seconds': 180,
                       'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}}
            with patch.object(worker, 'analyze_audio', return_value=profile) as analyze:
                before = session.measure('Original')
                after = session.measure('Completion check')
                self.assertEqual(analyze.call_count, 1)
                self.assertEqual(before['title'], 'Original')
                self.assertEqual(after['title'], 'Completion check')
                session.measure('After edit')
                self.assertEqual(analyze.call_count, 2)
            self.assertEqual(len(calls), 3)  # Native guard still runs on every request.
            self.assertEqual([t['reused'] for t in session.timings], [False, True, False])

    def test_short_diagnostics_never_replace_full_final_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp); worker.write(path/'config.json', {'bounds': [100, 280], 'rounds': 2})
            requests = []; renders = []
            def api(route, payload):
                requests.append(payload)
                if len(requests) == 1:
                    return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                        {'id': 'short', 'function': {'name': 'measure_mix', 'arguments': '{}'}}]}}]}
                return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured summary.'}}]}
            session = worker.Session(path, api)
            def bridge(name, args):
                if name == 'inspect_project': return PROJECT
                renders.append(args)
                return {'path': str(path/('render-%d.wav' % len(renders)))}
            session.bridge = bridge
            def analyze(*args):
                duration = renders[-1].get('duration_seconds', 180)
                # A peak outside the diagnostic must still block Keep.
                peak = .1 if len(renders) >= 3 else -2
                return {'duration_seconds': duration,
                        'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': peak}}
            with patch.object(worker, 'analyze_audio', side_effect=analyze), \
                 patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
                self.assertEqual(session.run(), 'review_warning')
            self.assertEqual(renders, [{}, {'start_seconds': 100, 'duration_seconds': 30}, {}, {}])
            diagnostic = worker.read(path/'latest-diagnostic.json')
            self.assertEqual(diagnostic['measurement_bounds'], [100, 130])
            self.assertEqual(diagnostic['envelope_time_origin_seconds'], 100)
            self.assertTrue(all(p['measurement_kind'] == 'full_passage' for p in session.measurements))
            self.assertEqual(session.measurements[-1]['loudness']['true_peak_dbtp'], .1)

    def test_argument_validation(self):
        specs = {t['function']['name']: t['function']['parameters'] for t in worker.TOOLS}
        worker.validate({'track': 'guid', 'volume_db': -3, 'pan': .2}, specs['set_track_mix'])
        worker.validate({'track': 'guid', 'volume_db': 18, 'pan': .2}, specs['set_track_mix'])
        worker.validate({'track': 'MASTER', 'effect': 'fx', 'gain_db': 18, 'ceiling_db': -1.2}, specs['configure_limiter'])
        with self.assertRaises(ValueError):
            worker.validate({'track': 'MASTER', 'effect': 'fx', 'gain_db': 18, 'ceiling_db': 0}, specs['configure_limiter'])
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

    def test_reference_gaps_use_signed_medians_and_keep_reference_range(self):
        original = {'loudness': {'integrated_lufs': -24, 'true_peak_dbtp': -6},
                    'side_energy_fraction': .1,
                    'bands': [{'low_hz': 60, 'high_hz': 150, 'relative_db': -4}]}
        refs = [{'loudness': {'integrated_lufs': lu, 'true_peak_dbtp': peak},
                 'side_energy_fraction': width,
                 'bands': [{'low_hz': 60, 'high_hz': 150, 'relative_db': band}]}
                for lu, peak, width, band in [(-10, .2, .3, -8), (-14, -1, .5, -10)]]
        result = worker.reference_comparison(original, refs)
        level = result['metrics']['integrated_lufs']
        self.assertEqual(level['reference_median'], -12)
        self.assertEqual(level['reference_range'], [-14, -10])
        self.assertEqual(level['delta_to_reference'], 12)
        self.assertEqual(result['bands'][0]['delta_to_reference'], -5)
        self.assertAlmostEqual(result['metrics']['side_energy_fraction']['delta_to_reference'], .3)
        # Source measurements, including a hot reference's peak, are not normalized or rewritten.
        self.assertEqual(refs[0]['loudness']['true_peak_dbtp'], .2)
        self.assertEqual(original['loudness']['integrated_lufs'], -24)

    def test_reference_gaps_handle_missing_metrics_and_incompatible_bands(self):
        self.assertIsNone(worker.reference_comparison({}, []))
        result = worker.reference_comparison(
            {'loudness': {'integrated_lufs': None},
             'bands': [{'low_hz': 20, 'high_hz': 60, 'relative_db': -10}]},
            [{'loudness': {'integrated_lufs': -12, 'loudness_range_lu': None},
              'bands': [{'low_hz': 30, 'high_hz': 60, 'relative_db': -5}]},
             {'loudness': {'integrated_lufs': float('nan'), 'true_peak_dbtp': float('inf')},
              'lr_correlation': True}])
        level = result['metrics']['integrated_lufs']
        self.assertIsNone(level['current'])
        self.assertIsNone(level['delta_to_reference'])
        self.assertEqual(level['reference_count'], 1)
        self.assertNotIn('true_peak_dbtp', result['metrics'])
        self.assertNotIn('lr_correlation', result['metrics'])
        self.assertNotIn('loudness_range_lu', result['metrics'])
        self.assertEqual(result['bands'], [])
        json.dumps(result, allow_nan=False)

    def test_reference_gaps_reach_model_and_refresh_after_actual_measurements(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            worker.write(path/'config.json', {'bounds': [0, 8], 'references': ['chosen'], 'rounds': 2})
            worker.write(path/'reference.json', {
                'title': 'Reference', 'source_name': 'private-source.wav',
                'loudness': {'integrated_lufs': -12, 'true_peak_dbtp': -1},
                'bands': [{'low_hz': 60, 'high_hz': 150, 'relative_db': -9}]})
            requests = []
            def api(route, payload):
                requests.append(json.loads(json.dumps(payload)))
                if len(requests) == 1:
                    return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                        {'id': 'meter', 'function': {'name': 'measure_mix', 'arguments': '{}'}}]}}]}
                return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured result.'}}]}
            session = worker.Session(path, api)
            session.bridge = lambda name, args: PROJECT if name == 'inspect_project' else {'path': str(path/'render.wav')}
            measurements = [{'duration_seconds': 8,
                             'loudness': {'integrated_lufs': lu, 'true_peak_dbtp': -2},
                             'bands': [{'low_hz': 60, 'high_hz': 150, 'relative_db': band}]}
                            for lu, band in [(-24, -3), (-15, -7), (-15, -7), (-15, -7)]]
            lib = {'references': [{'id': 'chosen', 'profile': str(path/'reference.json')},
                                  {'id': 'unused', 'profile': str(path/'must-not-read.json')}]}
            with patch.object(worker, 'library', return_value=lib), \
                 patch.object(worker, 'analyze_audio', side_effect=measurements), \
                 patch('charts.render_charts'):
                self.assertEqual(session.run(), 'review')
            context = json.loads(requests[0]['messages'][1]['content'])
            before = context['original']['reference_comparison']
            self.assertEqual(before['metrics']['integrated_lufs']['delta_to_reference'], 12)
            self.assertEqual(before['bands'][0]['delta_to_reference'], -6)
            tools = [m for m in requests[1]['messages'] if m['role'] == 'tool']
            after = json.loads(tools[0]['content'])['reference_comparison']
            self.assertEqual(after['metrics']['integrated_lufs']['delta_to_reference'], 3)
            self.assertEqual(after['bands'][0]['delta_to_reference'], -2)
            self.assertNotIn('private-source.wav', json.dumps(requests))
            self.assertEqual(worker.read(path/'measurements.json')[-1]['reference_comparison'], after)
            self.assertEqual(len(context['references']), 1)

    def test_actual_file_bridge_and_cancel(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json', {'bounds': [0, 8]})
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

    def test_silent_measurement_is_never_a_reference_match(self):
        reference = {'loudness': {'integrated_lufs': -12, 'true_peak_dbtp': -1}}
        for refs in ([], [reference]):
            for loudness in ({'integrated_lufs': None, 'true_peak_dbtp': None},
                             {'integrated_lufs': None, 'true_peak_dbtp': -2}):
                issues = worker.reference_issues({'loudness': loudness}, refs)
                self.assertTrue(issues)
                self.assertIn('silent or unmeasurable', issues[0])

    def test_invalid_track_measurement_can_be_corrected_without_aborting(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            worker.write(path/'config.json', {'bounds': [0,8], 'rounds': 3})
            requests = []
            def api(route, payload):
                requests.append(json.loads(json.dumps(payload)))
                if len(requests) == 1:
                    return {'choices': [{'message': {'role': 'assistant', 'tool_calls': [
                        {'id': 'bad-track', 'function': {'name': 'measure_track',
                         'arguments': '{"track":"not-a-real-guid"}'}}]}}]}
                return {'choices': [{'message': {'role': 'assistant', 'content': 'Measured summary.'}}]}
            session = worker.Session(path, api)
            def bridge(name, args):
                if name == 'inspect_project':
                    return PROJECT
                if name == 'measure_track':
                    return {'error': 'Track no longer exists', 'fatal': False}
                return {'path': str(path/'mix.wav')}
            session.bridge = bridge
            profile = {'duration_seconds': 8, 'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}}
            with patch.object(worker, 'library', return_value={'references': []}), \
                 patch.object(worker, 'analyze_audio', return_value=profile), patch('charts.render_charts'):
                self.assertEqual(session.run(), 'review')
            self.assertEqual(len(requests), 2)
            self.assertIn('Track no longer exists', requests[1]['messages'][3]['content'])
            self.assertEqual(len(session.measurements), 3)

    def test_unmeasurable_final_loudness_prevents_keep_even_with_a_peak(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            worker.write(path/'config.json', {'bounds': [0, 8], 'rounds': 1})
            session = worker.Session(path, lambda *a: {'choices': [{'message': {
                'role': 'assistant', 'content': 'Summary.'}}]})
            session.bridge = lambda *a: PROJECT
            with patch.object(session, 'measure', side_effect=[
                    {'loudness': {'integrated_lufs': -14, 'true_peak_dbtp': -2}},
                    {'loudness': {'integrated_lufs': None, 'true_peak_dbtp': -2}},
                    {'loudness': {'integrated_lufs': None, 'true_peak_dbtp': -2}}]), \
                 patch.object(worker, 'library', return_value={'references': []}), patch('charts.render_charts'):
                self.assertEqual(session.run(), 'review_warning')
            self.assertTrue(session.reference_issues)

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
            session.bridge=lambda name,args: executed.append((name,args)) or PROJECT
            def measure(label, track_id=None, window=None):
                profile={'title':label,'loudness':{'integrated_lufs':-18,'true_peak_dbtp':-3}}
                session.measurements.append(profile)
                return profile
            session.measure=measure
            with patch.object(worker,'library',return_value={'references':[]}):
                self.assertEqual(session.run(), 'review')
            self.assertEqual([e[0] for e in executed], ['inspect_project','set_track_mix'])
            self.assertEqual(len(session.measurements),3)
            self.assertIn('Unknown tool', requests[1]['messages'][3]['content'])
            self.assertEqual(len(requests[1]['tools']),len(worker.TOOLS))
            self.assertEqual(requests[0]['model'], 'openai/gpt-6-luna')
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
                session.bridge=lambda *a: PROJECT
                session.measure=lambda *a: {'loudness':{'integrated_lufs':-14,'true_peak_dbtp':peak}}
                with patch.object(worker,'library',return_value={'references':[]}):
                    self.assertEqual(session.run(), 'error' if should_fail else 'review_warning')

    def test_old_bridge_is_rejected_before_spending_api_credit(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json',{'bounds':[0,8]})
            session=worker.Session(path,lambda *a: self.fail('Old bridge must not call API'))
            session.bridge=lambda *a: {'tracks':[]}
            self.assertEqual(session.run(),'error')
            self.assertIn('Reopen Solo Studio',session.events[-1]['text'])

    def run_scripted_responses(self, responses, profile, reference=None, **config):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp);worker.write(path/'config.json',{'bounds':[0,8], 'rounds':8, **config})
            requests=[];mutations=[]
            def api(route,payload):
                requests.append(json.loads(json.dumps(payload)))
                return responses[min(len(requests)-1,len(responses)-1)]
            session=worker.Session(path,api)
            session.bridge=lambda name,args: PROJECT if name=='inspect_project' else mutations.append((name,args)) or {'ok':True}
            def measure(label,track_id=None,window=None):
                current=json.loads(json.dumps(profile));session.measurements.append(current);return current
            session.measure=measure
            lib={'references':[]}
            if reference:
                worker.write(path/'ref.json',reference)
                lib={'references':[{'id':'ref','profile':str(path/'ref.json')}]}
                session.config['references']=['ref']
            with patch.object(worker,'library',return_value=lib), patch('charts.render_charts'):
                state=session.run()
            return session,state,requests,mutations

    def test_empty_or_length_response_cannot_end_a_mix_silently(self):
        for finish in ['stop','length']:
            responses=[{'choices':[{'finish_reason':finish,'message':{'role':'assistant','content':None}}]},
                       {'choices':[{'finish_reason':'stop','message':{'role':'assistant','content':'Measured summary.'}}]}]
            session,state,requests,_=self.run_scripted_responses(responses,{'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}})
            self.assertEqual(len(requests),2)
            self.assertEqual(state,'review')
            self.assertEqual(session.completion_reason,'measured_completion')
            self.assertTrue(any('empty or truncated' in e['text'] for e in session.events))
            self.assertGreaterEqual(requests[0]['max_tokens'],8000)
        session,_,requests,_=self.run_scripted_responses(responses[:1],{'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}})
        self.assertEqual(len(requests),3)
        self.assertEqual(session.completion_reason,'incomplete_model_response')
        self.assertNotIn('Candidate ready.',session.events[-1]['text'])

    def test_truncated_tool_batch_is_never_partially_executed(self):
        responses=[{'choices':[{'finish_reason':'length','message':{'role':'assistant','tool_calls':[
            {'id':'partial','function':{'name':'set_track_mix','arguments':json.dumps({'track':'g','volume_db':18,'pan':0})}}]}}]},
            {'choices':[{'message':{'role':'assistant','content':'Summary'}}]}]
        _,_,requests,mutations=self.run_scripted_responses(responses,{'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}})
        self.assertEqual(mutations,[])
        self.assertIn('no changes',requests[1]['messages'][3]['content'])

    def test_whole_session_tool_batches_do_not_hit_the_old_twelve_call_limit(self):
        for count in (20, 33):
            batch={'choices':[{'message':{'role':'assistant','tool_calls':[
                {'id':str(i),'function':{'name':'set_track_mix','arguments':json.dumps({'track':'g','volume_db':i%20,'pan':0})}}
                for i in range(count)]}}]}
            done={'choices':[{'message':{'role':'assistant','content':'Summary'}}]}
            _,state,requests,mutations=self.run_scripted_responses([batch,done],{'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}})
            self.assertEqual(state,'review')
            self.assertEqual(len(requests),2)
            self.assertEqual(len(mutations),count if count<=32 else 0)
            if count>32:
                self.assertIn('none were applied',requests[1]['messages'][3]['content'])

    def test_off_target_mix_is_retried_and_reported_honestly(self):
        done={'choices':[{'message':{'role':'assistant','content':'Done'}}]}
        measured={'loudness':{'integrated_lufs':-22.4,'true_peak_dbtp':-3.2}}
        ref={'loudness':{'integrated_lufs':-8.9,'true_peak_dbtp':.5}}
        session,state,requests,_=self.run_scripted_responses([done],measured,ref)
        self.assertEqual(len(requests),4)  # Three bounded completion challenges.
        self.assertEqual(state,'review')  # User can still audition and keep an imperfect result.
        self.assertEqual(session.completion_reason,'reference_gap')
        self.assertIn('13.5 LU quieter',session.reference_issues[0])
        self.assertIn('reference targets still off',session.events[-1]['text'])
        self.assertIn('MASTER',requests[1]['messages'][-1]['content'])

    def test_completion_retries_respect_cost_and_round_limits(self):
        done={'choices':[{'message':{'role':'assistant','content':'Done'}}],'usage':{'cost':.25}}
        measured={'loudness':{'integrated_lufs':-22,'true_peak_dbtp':-3}}
        ref={'loudness':{'integrated_lufs':-9,'true_peak_dbtp':-1}}
        session,_,requests,_=self.run_scripted_responses([done],measured,ref,stop_after_usd=.1)
        self.assertEqual(len(requests),1)
        self.assertEqual(session.completion_reason,'cost_limit')
        _,_,requests,_=self.run_scripted_responses([done],measured,ref,rounds=1)
        self.assertEqual(len(requests),1)

    def test_long_passes_continue_past_twenty_and_keep_cost_stop(self):
        tool={'choices':[{'message':{'role':'assistant','tool_calls':[
            {'id':'move','function':{'name':'set_track_mix','arguments':json.dumps({'track':'g','volume_db':1,'pan':0})}}]}}]}
        done={'choices':[{'message':{'role':'assistant','content':'Measured summary.'}}]}
        profile={'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}}
        session,state,requests,moves=self.run_scripted_responses([tool]*25+[done],profile,rounds=60)
        self.assertEqual((len(requests),len(moves),state),(26,25,'review'))
        self.assertEqual(session.completion_reason,'measured_completion')
        session,_,requests,_=self.run_scripted_responses([tool],profile,rounds=1000)
        self.assertEqual(len(requests),100)
        self.assertEqual(session.completion_reason,'round_limit')
        expensive={**tool,'usage':{'cost':1.1}}
        session,_,requests,_=self.run_scripted_responses([expensive],profile,rounds=60,stop_after_usd=2)
        self.assertEqual(len(requests),2)
        self.assertEqual(session.completion_reason,'cost_limit')

    def test_repeated_tool_errors_pause_with_visible_reasons_and_final_measurement(self):
        bad={'choices':[{'message':{'role':'assistant','tool_calls':[
            {'id':'bad','function':{'name':'measure_mix','arguments':'{"start_seconds":0}'}}]}}]}
        good={'choices':[{'message':{'role':'assistant','tool_calls':[
            {'id':'good','function':{'name':'inspect_project','arguments':'{}'}}]}}]}
        done={'choices':[{'message':{'role':'assistant','content':'Summary'}}]}
        profile={'loudness':{'integrated_lufs':-14,'true_peak_dbtp':-2}}
        session,state,requests,_=self.run_scripted_responses([bad],profile,rounds=60)
        self.assertEqual(len(requests),3)
        self.assertEqual(session.completion_reason,'repeated_tool_errors')
        self.assertEqual(state,'review')
        self.assertEqual(len(session.measurements),2)  # Original + final still measured.
        self.assertTrue(any('failed: Supply both' in e['text'] for e in session.events))
        session,_,requests,_=self.run_scripted_responses([bad,bad,good,bad,bad,done],profile,rounds=60)
        self.assertEqual(len(requests),6)
        self.assertEqual(session.completion_reason,'measured_completion')

    def test_model_catalog_filters_routes_and_pins_default(self):
        now=1_790_000_000
        def model(ident, age=0, tools=True):
            return {'id':ident,'name':ident,'created':now-age*86400,
                    'supported_parameters':['tools','tool_choice'] if tools else [],
                    'pricing':{'prompt':'0.000001','completion':'0.000005'}}
        rows=[model('anthropic/top'),model('openai/gpt-6-astra'),
              model('openai/gpt-6-luna:batch'),model('old/model',181),
              model('no/tools',tools=False),model(worker.DEFAULT_MODEL),
              model(worker.DEFAULT_MODEL),model('openai/gpt-6-sol'),model('openai/older')]
        result=worker.model_shortlist({'data':rows},now)
        self.assertEqual([r['id'] for r in result],
                         [worker.DEFAULT_MODEL,'anthropic/top','openai/gpt-6-astra','openai/gpt-6-sol'])
        self.assertEqual(result[0]['input_per_million'],1)
        self.assertEqual(result[0]['output_per_million'],5)

    def test_model_refresh_failure_preserves_cache_and_finishes(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'models.json'
            saved={'models':[{'id':worker.DEFAULT_MODEL,'name':'GPT-6 Luna'}],
                   'updated':123,'pending':True}
            worker.write(path,saved)
            with patch.object(worker.urllib.request,'urlopen',side_effect=OSError('offline')):
                worker.refresh_models(path)
            result=worker.read(path)
            self.assertEqual(result['models'],saved['models'])
            self.assertEqual(result['updated'],123)
            self.assertNotIn('pending',result)
            self.assertIn('error',result)


if __name__=='__main__':
    unittest.main()
