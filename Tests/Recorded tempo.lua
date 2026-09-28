local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local count=0
local function check(ok,name)assert(ok,name);count=count+1;print('PASS: '..name)end
local function fixture()
 local f={tracks={},state=0,bpm=120,map={},ext={},runtime={},time=1,queue={},serial=0,valid=true}
 local R={GetProjExtState=function(_,_,k)return 1,f.ext[k]or ''end,SetProjExtState=function(_,_,k,v)f.ext[k]=v end,
  ValidatePtr=function()return f.valid end,GetPlayStateEx=function()return f.state end,
  GetExtState=function(_,k)return f.runtime[k]or ''end,SetExtState=function(_,k,v)f.runtime[k]=v end,Undo_OnStateChangeEx2=function()end,
  GetSetMediaItemInfo_String=function(it,k,v,set)if set then it[k]=v;return true,v end;return true,it[k]or ''end,
  CountTracks=function()return #f.tracks end,GetTrack=function(_,i)return f.tracks[i+1]end,GetTrackGUID=function(tr)return tr.id end,
  CountTrackMediaItems=function(tr)return #tr.items end,GetTrackMediaItem=function(tr,i)return tr.items[i+1]end,
  TimeMap_GetTimeSigAtTime=function()return 4,4,f.bpm end,CountTempoTimeSigMarkers=function()return #f.map end,
  GetTempoTimeSigMarker=function(_,i)local m=f.map[i+1];return true,m.t,0,0,m.bpm,4,4,m.linear end,
  MarkProjectDirty=function()end,UpdateTimeline=function()end,genGuid=function()f.serial=f.serial+1;return 'job'..f.serial end,
  time_precise=function()return f.time end,set_action_options=function()end,
  EnumProjects=function(i)if i==-1 or i==0 then return 'project'end end,
  defer=function(fn)f.queue[#f.queue+1]=fn end}
 reaper=R
 local Q=dofile(root..'/Scripts/solo_recorded_tempo.lua')({ns='test'})
 function f.add(tr,id)local it={GUID=id};tr.items[#tr.items+1]=it;return it end
 function f.tick()f.time=f.time+1;local fn=table.remove(f.queue,1);assert(fn);fn()end
 function f.watch()
  local env=setmetatable({reaper=R,dofile=function(path)
   if path:match('solo_recorded_tempo.lua$')then return function()return Q end end
   return dofile(path)
  end},{__index=_G})
  assert(loadfile(root..'/Scripts/Solo Studio - Store recording tempo.lua','t',env))()
 end
 for _,id in ipairs({'kick','snare','guitar'})do f.tracks[#f.tracks+1]={id=id,items={}}end
 return f,Q
end
local f,Q=fixture();local old=f.add(f.tracks[1],'old')
local token=Q.begin('project',{f.tracks[1],f.tracks[2]})
local pending=f.ext[Q.job_key]
f.state=5;Q.observe('project',Q.job('project'))
local a=f.add(f.tracks[1],'newkick');local b=f.add(f.tracks[2],'newsnare');local other=f.add(f.tracks[3],'other')
check(not Q.finish('project')and not Q.read(a),'Recording remains unmodified until it is kept')
f.state=0;f.bpm=130;Q.finish('project',token)
check(Q.read(a).bpm==120 and Q.read(b).bpm==120,'New mic clips retain the tempo captured before recording, not the later song tempo')
check(not Q.read(old)and not Q.read(other),'Existing and unrelated recordings never get guessed tempo labels')
check(Q.describe({a}).different and Q.describe({a}).label=='120 BPM','Known mismatches are visible after the song tempo changes')
f.bpm=120;check(not Q.describe({a}).different,'Returning to the recorded tempo clears the mismatch')
check(Q.describe({old}).unknown and not Q.describe({old}).different,'Unknown old takes are excluded from mismatch selection')
check(Q.describe({a,old}).mixed and not Q.describe({a,old}).different,'Partly known takes are excluded from bulk mismatch selection')
check(not Q.job('project')and not Q.finish('project',token),'Finishing twice cannot relabel old clips')
f.ext[Q.job_key]=pending
check(not Q.job('project')and not Q.finish('project'),'Undo cannot restart an already completed recording job')
f,Q=fixture();Q.begin('project',{f.tracks[1],f.tracks[2]});f.state=5;f.watch()
local items={}
for i=1,3 do for n=1,2 do items[#items+1]=f.add(f.tracks[n],'loop'..i..n)end end
f.state=0;f.tick()
local all=true;for _,it in ipairs(items)do all=all and Q.read(it).bpm==120 end
check(all and #f.queue==0,'Independent helper labels every loop pass on native Stop without the panel')
Q.begin('project',{f.tracks[1]});local next_item=f.add(f.tracks[1],'next');Q.finish('project')
f.bpm=150;Q.begin('project',{f.tracks[1]});local last=f.add(f.tracks[1],'last');Q.finish('project')
check(Q.read(next_item).bpm==120 and Q.read(last).bpm==150,'Back-to-back takes keep their own recording tempos')
f,Q=fixture();Q.begin('project',{f.tracks[1]});f.state=5;f.watch();f.bpm=140;f.tick();a=f.add(f.tracks[1],'changed');f.state=0;f.tick()
check(Q.read(a).changed and Q.describe({a}).label=='Tempo changed'and not Q.describe({a}).different,'Tempo changes during recording are marked explicitly, not treated as a fixed BPM')
f,Q=fixture();f.map={{t=8,bpm=160,linear=true}};Q.begin('project',{f.tracks[1]});a=f.add(f.tracks[1],'mapped');Q.finish('project')
check(Q.read(a).markers[1].bpm==160 and Q.describe({a}).label=='Tempo map'and not Q.describe({a}).different,'Tempo maps are stored and excluded from single-BPM deletion selection')
f,Q=fixture();token=Q.begin('project',{f.tracks[1]});Q.begin('project',{f.tracks[1]});a=f.add(f.tracks[1],'replacement')
check(not Q.finish('project',token)and Q.job('project')~=nil,'An old recording token cannot finish a replacement job')
f.state=0;Q.finish('project');a[Q.field]='bad JSON'
check(Q.describe({a}).unknown,'Invalid clip metadata is treated as unknown')
f,Q=fixture();Q.begin('project',{f.tracks[1]});f.watch();f.time=122;f.tick()
check(not Q.job('project')and #f.queue==0,'A cancelled count-in leaves no tempo watcher running indefinitely')
f,Q=fixture()
local M=dofile(root..'/Scripts/solo_core.lua')
M.arm=function()end;M.require_tracks=function()return {f.tracks[1],f.tracks[2]}end
M.sections=function()return {prepare_record=function()end,start_watch=function()end,cancel_watch=function()end}end
reaper.GetPlayState=function()return f.state end
reaper.AddRemoveReaScript=function()return 999 end
reaper.Main_OnCommand=function(id)
 if id==1013 then f.state=5;for i=1,2 do f.add(f.tracks[i],'record'..f.serial..i)end
 elseif id==40667 then f.state=0 end
end
reaper.OnStopButton=function()f.state=0 end
M.record();M.stop();f.bpm=140;M.record();M.stop()
local actual=M.recorded_tempo()
check(actual.read(f.tracks[1].items[1]).bpm==120 and actual.read(f.tracks[2].items[2]).bpm==140,'Actual Record/Stop actions capture and finalize consecutive performances')
f,Q=fixture();Q.begin('project',{f.tracks[1]});f.state=5;f.watch();f.state=0;f.tick()
check(Q.job('project')~=nil and #f.queue==1,'Stop waits for native loop items that have not appeared yet')
a=f.add(f.tracks[1],'late-loop-item');f.tick()
check(Q.read(a).bpm==120 and not Q.job('project')and #f.queue==0,'Deferred loop publication still receives its recording metadata')
f,Q=fixture();Q.begin('project',{f.tracks[1]});f.state=5;f.watch();f.state=0;f.tick();f.tick()
check(not Q.job('project')and #f.queue==0,'Stopping before the punch cannot leave an empty metadata watcher running')
print(count..' recorded-tempo checks passed.')
