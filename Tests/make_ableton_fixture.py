"""Build an isolated native fixture with synthetic audio and optional user-owned AU/VST3 states.
Usage: python3 Tests/make_ableton_fixture.py /path/to/a/set-with-AU-and-VST3.als
No plugin states or song audio are committed. The supplied set is read only."""
import json,copy,wave,math,struct,sys,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'Ableton'))
from prepare import Import
if len(sys.argv)!=2: raise SystemExit(__doc__)
source=sys.argv[1]
out=Path('/private/tmp/Tests/solo-ableton-native-plan');out.mkdir(parents=True,exist_ok=True)
# Each invocation gets a fresh state directory; existing fixtures are preserved.
import time
plugin_plan=Import(source,out/('source-plan-'+str(time.time_ns()))).build()
p=copy.deepcopy(plugin_plan);p.update(name='Fixture',folder=str(out),automation=[],locators=[{'time':0,'name':'Intro'},{'time':4,'name':'Verse'}],tempo=[{'time':0,'bpm':120}],bpm=120)
base=copy.deepcopy(next(t for t in p['tracks']if t['type']=='AudioTrack'));main=p['tracks'][-1];base.update(devices=[],clips=[],lanes=['Comp'],sends=[],volume=.5,pan=.2,muted=False,solo=False,input='AudioIn/External/M14',midi_output='MidiOut/None',linked_group='-1',group='-1',output='AudioOut/Master')
group=copy.deepcopy(base);group.update(id='1',type='GroupTrack',name='Bus',volume=1,pan=0)
audio=copy.deepcopy(base);audio.update(id='2',type='AudioTrack',name='Guitar',group='1',output='AudioOut/GroupTrack',lanes=['Comp','Take 1'],sends=[{'id':'0','destination':'4','gain':.3,'enabled':True,'pre':False}])
au=copy.deepcopy(next(d for t in plugin_plan['tracks']for d in t['devices']if d.get('plugin',{}).get('kind')=='AuPluginInfo' and d.get('parameters')));vst=copy.deepcopy(next(d for t in plugin_plan['tracks']for d in t['devices']if d.get('plugin',{}).get('kind')=='Vst3PluginInfo'));audio['devices']=[au,vst]
midi=copy.deepcopy(base);midi.update(id='3',type='MidiTrack',name='Keys',group='1',output='AudioOut/GroupTrack')
ret=copy.deepcopy(base);ret.update(id='4',type='ReturnTrack',name='Reverb')
with wave.open(str(out/'tone.wav'),'wb')as f:
 f.setparams((1,2,8000,0,'NONE','not compressed'));f.writeframes(b''.join(struct.pack('<h',int(1000*math.sin(n*2*math.pi*220/8000)))for n in range(8000*16)))
c={'name':'Trimmed','lane':0,'context':'arrangement','source_id':'1','take_id':'1','muted':False,'notes':'fixture','gain':1,'pitch':0,'kind':'audio','media':str(out/'tone.wav'),'original_media':str(out/'tone.wav'),'media_status':'found','warped':True,'warp_mode':'0','position':4,'length':4,'offset':2,'stretch':[[0,2],[4,6]],'fade_in':.02,'fade_out':.03}
audio['clips']=[c,dict(c,lane=1,context='take'),dict(c,position=9,length=2,offset=0,stretch=[]),dict(c,position=12,length=1,offset=0,stretch=[],media='',media_status='missing')]
midi['clips']=[{'kind':'midi','name':'Keys','lane':0,'context':'arrangement','source_id':'2','take_id':'2','muted':False,'notes':'','gain':1,'pitch':0,'position':0,'length':4,'notes_midi':[{'start':0,'end':1,'pitch':60,'velocity':100,'muted':False},{'start':2,'end':3,'pitch':64,'velocity':80,'muted':False}],'cc':[{'time':1,'controller':66,'value':127}]}]
p['tracks']=[group,audio,midi,ret,main]
for kind in ['volume','pan','mute','send','parameter']:
 a={'kind':kind,'track':'2','points':[{'time':0,'value':.3,'step':False},{'time':4,'value':.7,'step':False}]}
 if kind=='mute':a['points']=[{'time':0,'value':1,'step':True},{'time':4,'value':1,'step':True}]
 if kind=='send':a['send']='0'
 if kind=='parameter':a.update(device=au['key'],parameter=au['parameters'][0]['id'])
 p['automation'].append(a)
if (out/'Fixture.RPP').exists(): (out/'Fixture.RPP').rename(out/('Fixture-'+str(time.time_ns())+'.RPP'))
(out/'import-plan.json').write_text(json.dumps(p));print([(d['name'],len(d['parameters']))for d in audio['devices']])
