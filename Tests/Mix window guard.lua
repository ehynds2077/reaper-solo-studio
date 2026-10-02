-- Presentation changes must not cancel mixing or hide genuine audio edits.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua')
local path=os.tmpname();os.remove(path);assert(os.execute('mkdir -p "'..path..'"'))
local template='<TRACK\nNAME "Bass"\nSEL 0\nVOLPAN 1 0\nMUTESOLO 0 0\nAUXRECV 0 0 1\n<FXCHAIN\nSHOW -1\nLASTSEL 0\nDOCKED 0\nBYPASS 0 0 0\n<VST "ReaEQ"\nopaque-plugin-state\n>\nFLOATPOS 20 30 400 300\nFXID {FX}\nWAK 0 0\n<PARMENV 0\nPT 0 0 0\n>\n>\n<ITEM\nPOSITION 0\nLENGTH 8\nSEL 0\n<SOURCE WAVE\nFILE "source.wav"\n>\n>\n>\n'
local master={id='master',chunk='<TRACK\nVOLPAN 1 0\n>\n',D_VOL=1,D_PAN=0}
local tr={id='bass',chunk=template,D_VOL=1,D_PAN=0}
local version,tempo,rate,override,play,project=1,120,1,-1,0,'song'
local passed=0
local function check(ok,name)assert(ok,name);passed=passed+1;print('PASS '..name)end
reaper={
 EnumProjects=function()return project,'song.rpp'end,GetPlayState=function()return play end,
 GetProjectStateChangeCount=function()return version end,
 CountTracks=function()return 1 end,GetTrack=function()return tr end,GetMasterTrack=function()return master end,
 GetTrackGUID=function(t)return t.id end,GetTrackStateChunk=function(t)return true,t.chunk end,
 GetMediaTrackInfo_Value=function(t,k)return t[k]end,TrackFX_GetCount=function()return 0 end,
 GetProjectTimeSignature2=function()return tempo,4 end,Master_GetPlayRate=function()return rate end,
 GetGlobalAutomationOverride=function()return override end,CountTempoTimeSigMarkers=function()return 0 end,
 Undo_CanUndo2=function()return 'Close FX config: Track 1 Bass: ReaEQ'end,
}
local S=dofile(root..'/Scripts/solo_mix_state.lua');local B=dofile(root..'/Scripts/solo_mix_bridge.lua')
local function session()
 tr.chunk=template;tr.D_VOL=1;tr.D_PAN=0;master.chunk='<TRACK\nVOLPAN 1 0\n>\n'
 tempo=120;rate=1;override=-1;play=0;project='song'
 local s={path=path,project=project,project_path='song.rpp',version=version,original=J.array({{id='bass',volume=1,pan=0}}),
  expected={bass={volume=1,pan=0}},owned=J.array(),bounds={0,8},mode='candidate',render_cache={saved={path='verified.wav'}}}
 s.audio_signature=S.capture(project);return s
end
local s=session()
for _,edit in ipairs({{'SHOW %-1','SHOW 0'},{'LASTSEL 0','LASTSEL 2'},{'DOCKED 0','DOCKED 1'},
 {'FLOATPOS 20 30 400 300','FLOATPOS 50 60 700 800'},{'FLOATPOS 50 60 700 800','FLOAT 50 60 700 800'},
 {'<FXCHAIN','<FXCHAIN\nWNDRECT 30 40 500 400'},{'SEL 0','SEL 1'}})do
 tr.chunk=tr.chunk:gsub(edit[1],edit[2]);version=version+1
 check(pcall(B.guard,s,true)and s.version==version and s.render_cache.saved.path=='verified.wav','Window/selection '..edit[2]..' keeps pass and verified render')
end
for _,edit in ipairs({{'opaque%-plugin%-state','different-plugin-state'},{'BYPASS 0 0 0','BYPASS 1 0 0'},
 {'BYPASS 0 0 0','BYPASS 0 1 0'},{'AUXRECV 0 0 1','AUXRECV 0 0 0.5'},
 {'PT 0 0 0','PT 0 0.5 0'},{'POSITION 0','POSITION 1'},{'source.wav','other.wav'},
 {'MUTESOLO 0 0','MUTESOLO 1 0'},{'VOLPAN 1 0','VOLPAN 0.5 0'},{'WAK 0 0','WAK 1 0'}})do
 s=session();tr.chunk=tr.chunk:gsub(edit[1],edit[2]):gsub('SHOW %-1','SHOW 0');version=version+2
 check(not pcall(B.guard,s,true)and s.version~=version,'Real edit '..edit[2]..' rejected even with Close FX undo label')
end
s=session();master.chunk='<TRACK\nVOLPAN 0.5 0\n>\n';version=version+1
check(not pcall(B.guard,s,true),'Master changes remain protected')
for _,key in ipairs({'tempo','rate','override'})do
 s=session();if key=='tempo'then tempo=130 elseif key=='rate'then rate=1.2 else override=0 end;version=version+1
 check(not pcall(B.guard,s,true),'Global '..key..' changes remain protected')
end
s=session();tr.D_PAN=.5
check(not pcall(B.guard,s,true),'Uncounted pan changes still rejected')
s=session();s.audio_signature=nil;version=version+1
check(not pcall(B.guard,s,true),'Missing fingerprint cannot authorize a version mismatch')
s=session();version=version+2
check(not pcall(B.guard,s,true),'Several unseen actions cannot hide behind the last window undo label')
s=session();version=version+1;local undo_label=reaper.Undo_CanUndo2
reaper.Undo_CanUndo2=function()return 'Project settings'end
check(not pcall(B.guard,s,true),'Unknown global settings edit remains protected even with unchanged chunks')
reaper.Undo_CanUndo2=undo_label
local payload=template:gsub('opaque%-plugin%-state','SHOW 100\nFLOATPOS 1 2 3 4')
check(S.normalize(payload)~=S.normalize(payload:gsub('SHOW 100','SHOW 101')),'UI-like tokens inside opaque plugin payload are retained')
s=session();J.write(path..'/snapshot.json',s);tr.chunk=tr.chunk:gsub('SHOW %-1','SHOW 0')
local recovered=B.recover(path)
check(not recovered.recovery_changed and pcall(B.guard,recovered,true),'Journal reload accepts window-only changes')
tr.chunk=tr.chunk:gsub('opaque%-plugin%-state','edited-state');recovered=B.recover(path)
check(recovered.recovery_changed and not pcall(B.guard,recovered,true),'Journal reload detects plugin edits beyond fader/pan')
s=session();play=4;check(not pcall(B.guard,s,true,true),'Recording guard remains active')
s=session();project='another';check(not pcall(B.guard,s,true),'Project switching remains protected')
os.remove(path..'/snapshot.json');os.remove(path..'/bridge-events.jsonl');os.remove(path)
print(passed..' mix window guard checks passed')
