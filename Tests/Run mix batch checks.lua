-- Ten EQs through the real Python batch worker/REAPER bridge, without network calls.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local J=B.json
local log=assert(io.open(root..'/Tests/mix-batch-checks.txt','w'))
if R.GetExtState('SoloStudio_v1','panel_open')=='1'or R.GetAllProjectPlayStates()~=0 then
 log:write('NOT RUN: Close Solo Studio and stop transport before these isolated checks.\n');log:close();return
end
local original=R.EnumProjects(-1,'');local original_chunks={};local count=0
local project,session,job;local passed=0
local function check(value,label)assert(value,label);passed=passed+1;log:write('PASS: '..label..'\n');log:flush()end
for i=0,R.CountTracks(original)-1 do
 local tr=R.GetTrack(original,i);local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok)
 original_chunks[R.GetTrackGUID(tr)]=chunk;count=count+1
end
local function cleanup(ok,err)
 if session then pcall(B.revert,session)end
 if project and R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,job..'/Batch checks.RPP',8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 local preserved=R.CountTracks(original)==count
 for i=0,R.CountTracks(original)-1 do
  local tr=R.GetTrack(original,i);local good,chunk=R.GetTrackStateChunk(tr,'',false)
  preserved=preserved and good and original_chunks[R.GetTrackGUID(tr)]==chunk
 end
 log:write(preserved and 'PASS: Original user track contents preserved exactly\n'or 'FAIL: User track preservation mismatch\n')
 log:write(ok and (passed..' native batch checks passed.\n')or ('FAIL: '..tostring(err)..'\n'));log:close()
 dofile(root..'/Launcher/launch.lua')
end
local ok,err=xpcall(function()
 job=root..'/Tests/Mix batch data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/Batch checks.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/Batch checks.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Disposable project has no hardware outputs')
 for i=0,9 do
  R.InsertTrackAtIndex(i,false);local tr=R.GetTrack(project,i)
  R.GetSetMediaTrackInfo_String(tr,'P_NAME','Synthetic guitar '..(i+1),true)
  R.SetMediaTrackInfo_Value(tr,'I_PANMODE',3);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0)
  if i<2 then
   local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
   local source=assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav'),'Generate mix-tone.wav first')
   R.SetMediaItemTake_Source(take,source);R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
  end
 end
 session=B.begin(job,{0,8});J.write(job..'/config.json',{bounds={0,8},visual_analysis=false})
 R.ExecProcess('/usr/bin/python3 -B "'..root..'/Mix/test_native_batches.py" "'..job..'"',-1)
end,debug.traceback)
if not ok then cleanup(false,err);return end
local handled='';local deadline=R.time_precise()+180
local function tick()
 local done=false
 local good,why=xpcall(function()
  local request=J.read(job..'/request.json')
  if request and request.id~=handled then
   handled=request.id
   local accepted,result=pcall(B.execute,session,request.name,request.arguments)
   J.write(job..'/response-'..request.id..'.json',accepted and {result=result}or {error=tostring(result),fatal=true})
  end
  local result=J.read(job..'/test-result.json')
  if result then
   check(result.ok,'Real batch worker: '..tostring(result.error or '30 edits, ten EQs, ten inspections and two track measurements'))
   check(session.renders==2,'Repeated batch measurements reuse both native renders')
   for i=0,9 do
    local tr=R.GetTrack(project,i)
    check(R.TrackFX_GetCount(tr)==1 and math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-10^(-6/20))<1e-8,'Track '..(i+1)..' has exactly one configured EQ and the requested fader')
   end
   B.compare(session,'original')
   check(R.GetMediaTrackInfo_Value(R.GetTrack(project,0),'D_VOL')==1 and not R.TrackFX_GetEnabled(R.GetTrack(project,9),0),'Original bypasses batch-added EQs and restores faders')
   B.compare(session,'candidate');check(R.TrackFX_GetEnabled(R.GetTrack(project,9),0),'Candidate restores batch-added effects')
   B.revert(session);session=nil
   local restored=true
   for i=0,9 do local tr=R.GetTrack(project,i);restored=restored and R.TrackFX_GetCount(tr)==0 and R.GetMediaTrackInfo_Value(tr,'D_VOL')==1 end
   check(restored,'Revert restores all ten original tracks')
   done=true;return
  end
  assert(R.time_precise()<deadline,'Native batch worker timed out')
 end,debug.traceback)
 if not good or done then cleanup(good,why)else R.defer(tick)end
end
tick()
