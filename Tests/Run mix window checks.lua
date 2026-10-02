-- Native window-only check on the active real project: no render/model/audio edits.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local S=dofile(root..'/Scripts/solo_mix_state.lua')
local log=assert(io.open(root..'/Tests/mix-window-native-checks.txt','w'))
local project=R.EnumProjects(-1,'');local chosen,index,chain,float,s,baseline
local passed=0
local function check(ok,name)assert(ok,name);passed=passed+1;log:write('PASS '..name..'\n');log:flush()end
local ok,err=xpcall(function()
 assert(R.GetAllProjectPlayStates()==0,'Stop transport before running this check')
 for i=0,R.CountTracks(project)-1 do
  local tr=R.GetTrack(project,i);local _,name=R.GetTrackName(tr)
  if name=='Bass'then
   for f=0,R.TrackFX_GetCount(tr)-1 do
    local _,plugin=R.TrackFX_GetFXName(tr,f,'')
    if plugin:find('ReaEQ',1,true)and not R.TrackFX_GetOffline(tr,f)then chosen=tr;index=f;break end
   end
  end
 end
 assert(chosen,'This check needs an online ReaEQ on Bass')
 chain=R.TrackFX_GetChainVisible(chosen);float=R.TrackFX_GetFloatingWindow(chosen,index)~=nil
 local job=root..'/Tests/Mix window check data';R.RecursiveCreateDirectory(job,0)
 local before={}
 for i=-1,R.CountTracks(project)-1 do
  local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i)
  local _,chunk=R.GetTrackStateChunk(tr,'',false);before[tostring(i)]=chunk
 end
 B.json.write(job..'/before.json',before)
 local started=R.time_precise();s=B.begin(job,{0,math.max(3,R.GetProjectLength(project))})
 baseline=s.audio_signature
 check(baseline~=nil,'Native audio fingerprint captured in '..string.format('%.3fs',R.time_precise()-started))
 R.TrackFX_Show(chosen,index,3)
end,debug.traceback)
local function finish(good,why)
 if chosen then
  R.TrackFX_Show(chosen,index,float and 3 or 2)
  if chain and chain>=0 then R.TrackFX_Show(chosen,chain,1)else R.TrackFX_Show(chosen,index,0)end
 end
 log:write(good and (passed..' native window checks passed\n')or ('FAIL '..tostring(why)..'\n'));log:close()
end
if not ok then finish(false,err);return end
local stage,deadline=1,R.time_precise()+.2
local function tick()
 if R.time_precise()<deadline then R.defer(tick);return end
 local good,why=xpcall(function()
  assert(R.EnumProjects(-1,'')==project,'Project changed during check')
  local signature=S.capture(project)
  if signature~=baseline then
   local after={}
   for i=-1,R.CountTracks(project)-1 do
    local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i)
    local _,chunk=R.GetTrackStateChunk(tr,'',false);after[tostring(i)]=chunk
   end
   B.json.write(root..'/Tests/Mix window check data/after.json',after)
  end
  check(signature==baseline,'Audio state unchanged after window step '..stage)
  check(pcall(B.guard,s,true),'Mix guard accepts window step '..stage)
  if stage==1 then R.TrackFX_Show(chosen,index,2)
  elseif stage==2 then R.TrackFX_Show(chosen,index,1)
  elseif stage==3 then R.TrackFX_Show(chosen,index,0)end
 end,debug.traceback)
 if not good or stage==4 then finish(good,why);return end
 stage=stage+1;deadline=R.time_precise()+.2;R.defer(tick)
end
tick()
