"""Run only from the disposable REAPER integration fixture. No network calls."""
import json
import sys
from pathlib import Path
import worker


def main():
    directory=Path(sys.argv[1]);calls=[]
    def scripted_model(route,payload):
        calls.append(route)
        project=json.loads(payload['messages'][1]['content'])['project']
        track=project['tracks'][0]['id']
        if len(calls)==1:
            operations=[('set_track_mix',{'track':track,'volume_db':9,'pan':0}),
                        ('add_effect',{'track':track,'plugin':'VST: ReaComp (Cockos)'}),
                        ('add_effect',{'track':'MASTER','plugin':'VST3: Pro-L 2 (FabFilter)'})]
        elif len(calls)==2:
            results=[json.loads(m['content']) for m in payload['messages'] if m['role']=='tool']
            compressor=next(r['effect'] for r in results if r.get('plugin')=='VST: ReaComp (Cockos)')
            limiter=next(r['effect'] for r in results if r.get('plugin')=='VST3: Pro-L 2 (FabFilter)')
            operations=[('configure_compressor',{'track':track,'effect':compressor,'threshold_db':-30,
                         'ratio':2,'attack_ms':5,'release_ms':100,'makeup_db':6}),
                        ('configure_limiter',{'track':'MASTER','effect':limiter,'gain_db':9,'ceiling_db':-1.2}),
                        ('measure_mix',{})]
        else:
            return {'choices':[{'message':{'role':'assistant','content':'Synthetic test complete; measured candidate ready.'}}]}
        if operations:
            return {'choices':[{'message':{'role':'assistant','content':'Synthetic test: raise level with source compression, makeup and master limiting.',
                'tool_calls':[{'id':str(i),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}
                              for i,(name,args) in enumerate(operations)]}}]}
    state=worker.Session(directory,scripted_model).run()
    assert state=='review',worker.read(directory/'status.json')
    assert len(calls)==3
    data=worker.read(directory/'measurements.json')
    timings=worker.read(directory/'status.json')['measurement_timings']
    assert timings[-1]['reused'] and timings[-2]['reused'], 'Unchanged completion/final checks must reuse rendering and analysis'
    assert data[-1]['loudness']['integrated_lufs'] > data[0]['loudness']['integrated_lufs']+10
    assert data[-1]['loudness']['true_peak_dbtp'] <= -1
    assert (directory/'comparison.png').exists()
    worker.write(directory/'test-result.json',{'ok':True,'model_requests':len(calls),
        'original_lufs':data[0]['loudness']['integrated_lufs'],'candidate_lufs':data[-1]['loudness']['integrated_lufs']})

if __name__=='__main__':
    try:
        main()
    except Exception as error:
        worker.write(Path(sys.argv[1])/'test-result.json',{'error':str(error)})
