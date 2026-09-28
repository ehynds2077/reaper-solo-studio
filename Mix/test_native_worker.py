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
            operations=[('set_track_mix',{'track':track,'volume_db':-9,'pan':0}),
                        ('set_trim_automation',{'track':track,'points':[
                            {'seconds':0,'db':0},{'seconds':1,'db':-3},
                            {'seconds':7,'db':-3},{'seconds':8,'db':0}]}),
                        ('measure_track',{'track':track})]
            return {'choices':[{'message':{'role':'assistant','content':'Synthetic test: lower the track and automate trim.',
                'tool_calls':[{'id':str(i),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}
                              for i,(name,args) in enumerate(operations)]}}]}
        return {'choices':[{'message':{'role':'assistant','content':'Synthetic test complete; measured candidate ready.'}}]}
    state=worker.Session(directory,scripted_model).run()
    assert state=='review',worker.read(directory/'status.json')
    assert len(calls)==2
    data=worker.read(directory/'measurements.json')
    assert data[-1]['loudness']['integrated_lufs'] < data[0]['loudness']['integrated_lufs']-7
    assert (directory/'comparison.png').exists()
    worker.write(directory/'test-result.json',{'ok':True,'model_requests':len(calls),
        'original_lufs':data[0]['loudness']['integrated_lufs'],'candidate_lufs':data[-1]['loudness']['integrated_lufs']})

if __name__=='__main__':
    try:
        main()
    except Exception as error:
        worker.write(Path(sys.argv[1])/'test-result.json',{'error':str(error)})
