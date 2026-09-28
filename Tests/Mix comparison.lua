-- Standalone regression checks for live mix review; no REAPER or audio device needed.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua')
local path=os.tmpname();os.remove(path);assert(os.execute('mkdir -p "'..path..'"'))
local play,version,project,undo,writes=0,1,'song',0,0
local tr={id='track',D_VOL=.5,D_PAN=.25,fx={{id='existing',enabled=true},{id='new',enabled=true},{id='bypassed',enabled=false}}}
reaper={
 EnumProjects=function()return project,'song.rpp'end,
 GetPlayState=function()return play end,
 GetProjectStateChangeCount=function()return version end,
 CountTracks=function()return 1 end,GetTrack=function()return tr end,GetTrackGUID=function(t)return t.id end,
 GetMediaTrackInfo_Value=function(t,k)return t[k]end,
 SetMediaTrackInfo_Value=function(t,k,v)t[k]=v;writes=writes+1 end,
 TrackFX_GetCount=function(t)return #t.fx end,
 TrackFX_GetFXGUID=function(t,i)return t.fx[i+1].id end,
 TrackFX_GetEnabled=function(t,i)return t.fx[i+1].enabled end,
 TrackFX_SetEnabled=function(t,i,v)t.fx[i+1].enabled=v;writes=writes+1 end,
 TrackFX_Delete=function(t,i)table.remove(t.fx,i+1);writes=writes+1 end,
 Undo_BeginBlock2=function()undo=undo+1 end,
 Undo_EndBlock2=function()undo=undo-1;version=version+1 end,
 UpdateArrange=function()end,
}
-- Any attempted transport/cursor API call fails because it is deliberately absent.
local B=dofile(root..'/Scripts/solo_mix_bridge.lua')
local passed=0
local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local function session()
 tr.D_VOL=.5;tr.D_PAN=.25;project='song'
 tr.fx={{id='existing',enabled=true},{id='new',enabled=true},{id='bypassed',enabled=false}}
 return {path=path,project=project,project_path='song.rpp',version=version,original={{id=tr.id,volume=1,pan=0}},
  owned={{track=tr.id,id='new'},{track=tr.id,id='bypassed'}},expected={[tr.id]={volume=.5,pan=.25}},mode='candidate',bounds={0,8}}
end
local s=session()
for _,transport in ipairs({0,1,2,3})do
 play=transport
 for n=1,3 do
  B.compare(s,'original')
  check(tr.D_VOL==1 and tr.D_PAN==0 and not tr.fx[2].enabled and not tr.fx[3].enabled and play==transport,'Original, transport '..transport..', switch '..n)
  B.compare(s,'candidate')
  check(tr.D_VOL==.5 and tr.D_PAN==.25 and tr.fx[2].enabled and not tr.fx[3].enabled and tr.fx[1].enabled and play==transport,'Candidate, transport '..transport..', switch '..n)
 end
end
for _,transport in ipairs({4,5,6,7})do
 play=transport
 for _,f in ipairs({function()B.compare(s,'original')end,function()B.keep(s)end,function()B.revert(s)end})do
  local before=writes;check(not pcall(f)and writes==before,'Recording '..transport..' blocks review writes')
 end
end
play=1
check(not pcall(B.execute,s,'measure_mix',{}),'Agent renders still require stopped transport')
check(not pcall(B.guard,s,true),'Agent mutations still require stopped transport')
local before=writes
version=version+1
check(not pcall(B.compare,s,'original')and writes==before,'External project edit remains protected during playback')
s.version=version;tr.D_PAN=.6
check(not pcall(B.compare,s,'original')and writes==before,'Uncounted manual fader/pan edit remains protected')
check(B.revert(s)==1 and tr.D_PAN==.6 and tr.D_VOL==1 and #tr.fx==1 and play==1,'Live revert preserves manual pan and existing FX without stopping')
s=session();B.keep(s)
check(s.finished and tr.D_VOL==.5 and #tr.fx==3 and play==1,'Live keep preserves candidate and playback')
s=session();B.compare(s,'original')
check(not pcall(B.keep,s),'Cannot keep the Original as a measured candidate')
local recovered=B.recover(path);B.compare(recovered,'candidate')
check(tr.fx[2].enabled and not tr.fx[3].enabled and tr.D_VOL==.5,'Journal round trip preserves candidate bypass and gain')
s=session();tr.fx[3]=nil;before=writes
check(not pcall(B.compare,s,'original')and writes==before and s.candidate==nil,'Missing effect fails before partial A/B changes')
s=session();B.compare(s,'original');s.candidate[tr.id]=nil;before=writes
check(not pcall(B.compare,s,'candidate')and writes==before,'Incomplete candidate fails before partial A/B changes')
s=session();project='another song';before=writes
check(not pcall(B.compare,s,'original')and writes==before,'Project switching blocks live A/B')
check(undo==0,'Undo blocks are balanced')
os.remove(path..'/snapshot.json');os.remove(path)
print(passed..' mix comparison checks passed')
