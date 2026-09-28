local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(v,label)assert(v,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={project='p',valid=true,state={},runtime={},preroll=1,linked=1,loop={8,12},time={8,12},recording=false,serial=0}
 reaper={
  ValidatePtr=function()return f.valid end,
  GetProjExtState=function(_,_,key)return 1,f.state[key]or''end,SetProjExtState=function(_,_,key,value)f.state[key]=value end,
  GetExtState=function(_,key)return f.runtime[key]or''end,SetExtState=function(_,key,value)f.runtime[key]=value end,DeleteExtState=function(_,key)f.runtime[key]=nil end,
  genGuid=function()f.serial=f.serial+1;return 'job'..f.serial end,
  GetToggleCommandStateEx=function(_,cmd)return cmd==41819 and f.preroll or f.linked end,
  Main_OnCommandEx=function(cmd)if cmd==41819 then f.preroll=1-f.preroll elseif cmd==40621 then f.linked=1-f.linked else error('Unexpected action')end end,
  GetPlayStateEx=function()return f.recording and 5 or 0 end,
  GetSet_LoopTimeRange2=function(_,set,loop,a,b)if set then if loop then f.loop={a,b};if f.linked==1 then f.time={a,b}end else f.time={a,b};if f.linked==1 then f.loop={a,b}end end end;return table.unpack(loop and f.loop or f.time)end,
  TimeMap2_timeToBeats=function(_,t)local m=math.floor(t/2);return (t-m*2)*2,m,4 end,
  TimeMap2_beatsToTime=function(_,beat,m)return m*2+beat/2 end,
  GetActiveTake=function(it)return it.take end,TakeIsMIDI=function()return false end,
  GetMediaItemTake_Source=function(t)return t.src end,GetMediaSourceLength=function(src)return src.length,false end,
  GetMediaSourceFileName=function(src)return src.file end,
  GetMediaItemInfo_Value=function(it,k)return it[k]end,GetMediaItemTakeInfo_Value=function(t,k)return t[k]end,
  GetSetMediaItemInfo_String=function(it,k,v,set)if set then it[k]=v end;return true,it[k]or''end,
 }
 f.H=dofile(root..'/Scripts/solo_recording_handles.lua')
 f.S=dofile(root..'/Scripts/solo_sections.lua')({});return f
end
local f=fixture();local a,b=f.S.record_bounds({s=8,e=12})
check(a==4 and b==16,'Section capture adds two musical bars on each side')
a,b=f.S.record_bounds({s=8.5,e=12.5});check(a==4.5 and b==16.5,'Off-grid section bounds preserve their beat position in both handles')
a,b=f.S.record_bounds({s=1,e=3});check(a==0 and b==7,'The lead-in stops at project time zero while the tail keeps its full two bars')
reaper.TimeMap2_timeToBeats=function(_,t)if t<8 then local m=math.floor(t/2);return (t-m*2)*2,m,4 end;local m=4+math.floor((t-8)/4);return t-(8+(m-4)*4),m,4 end
reaper.TimeMap2_beatsToTime=function(_,beat,m)return m<4 and m*2+beat/2 or 8+(m-4)*4+beat end
a,b=f.S.record_bounds({s=8,e=12});check(a==4 and b==20,'Handles follow a tempo change instead of assuming a fixed number of seconds')
f=fixture();local job=f.H.prepare('p',4,16,8,true)
check(f.preroll==0 and f.linked==0 and f.loop[1]==4 and f.loop[2]==16 and f.time[1]==8 and f.time[2]==12,'Recorded lead-in avoids a doubled count-in and separates loop from visible punch bounds')
f.H.restore('p','stale');check(f.preroll==0 and f.H.job('p')~=nil,'An old helper cannot restore a replacement capture')
f.H.restore('p',job.token);check(f.preroll==1 and f.linked==1 and f.loop[1]==8 and f.loop[2]==12,'Stop restores native pre-roll, linked selection preference, and section loop bounds')
f=fixture();job=f.H.prepare('p',4,16,8,true);f.loop={2,20};f.H.restore('p',job.token)
check(f.loop[1]==2 and f.loop[2]==20,'Manual changes to loop bounds are retained')
f=fixture();job=f.H.prepare('p',4,16,8,true);f.valid=false;f.H.restore('p',job.token)
check(f.preroll==1 and f.linked==1 and not f.runtime['capture.global'],'Closing the recording project still restores global settings')
f=fixture();job=f.H.prepare('p',4,16,8,false);local saved=f.state[f.H.key];f.H.restore('p',job.token);f.state[f.H.key]=saved
check(not f.H.job('p'),'Undo cannot reactivate a completed capture-settings journal')
f=fixture();job=f.H.prepare('p',0,8,0,false);check(f.preroll==1,'Recording at song start keeps the native two-bar click lead-in')
f=fixture();job=f.H.prepare('p',4,16,8,false);f.recording=true;f.H.recover('p');check(f.preroll==0,'Opening a panel during capture does not restore settings prematurely')
f.recording=false;f.H.recover('p');check(f.preroll==1,'Opening after an interrupted capture recovers settings')
f=fixture();local src={length=27,file='loop.wav'};local it={D_POSITION=48,take={src=src,D_STARTOFFS=13,D_PLAYRATE=1}}
f.H.tag_item(it,{first=44,last=53});a,b=f.H.bounds(it,src)
check(a==9 and b==18,'Loop metadata restricts each pass to its own two-bar handles inside a shared WAV')
src.file='glued.wav';check(f.H.bounds(it,src)==nil,'Changing the underlying media cannot reuse stale handle limits')
src.file='loop.wav';src.length=15;f.H.tag_item(it,{first=44,last=53});a,b=f.H.bounds(it,src)
check(a==9 and b==15,'An early stop stores only the tail actually captured')
print(total..' section-handle checks passed.')
