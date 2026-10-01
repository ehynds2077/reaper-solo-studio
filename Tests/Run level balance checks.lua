-- Actual rendered level rides in a disposable project, using a scripted model.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local J=B.json
local log=assert(io.open(root..'/Tests/level-balance-checks.txt','w'))
if R.GetExtState('SoloStudio_v1','panel_open')=='1'or R.GetAllProjectPlayStates()~=0 then
 log:write('NOT RUN: Close Solo Studio and stop all transport first.\n');log:close();return
end
local original=R.EnumProjects(-1,'');local count=R.CountTracks(original);local chunks={}
for i=-1,count-1 do
 local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i)
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok);chunks[i]=chunk
end
local project,session,job;local passed=0
local function check(value,label)assert(value,label);passed=passed+1;log:write('PASS: '..label..'\n');log:flush()end
local function cleanup(ok,err)
 if session then pcall(B.revert,session)end
 if project and R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,job..'/Level checks.RPP',8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 local preserved=R.CountTracks(original)==count
 for i=-1,count-1 do
  local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i)
  local good,chunk=R.GetTrackStateChunk(tr,'',false);preserved=preserved and good and chunks[i]==chunk
 end
 log:write(preserved and 'PASS: Original track and master contents preserved exactly\n'or 'FAIL: Original contents changed\n')
 log:write(ok and (passed..' native leveling checks passed\n')or ('FAIL: '..tostring(err)..'\n'));log:close()
 dofile(root..'/Launcher/launch.lua')
end
local ok,err=xpcall(function()
 job=root..'/Tests/Level balance data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/Level checks.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/Level checks.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Disposable project has no hardware outputs')
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(project,0)
 R.GetSetMediaTrackInfo_String(tr,'P_NAME','Synthetic guitar',true);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0)
 for i=0,2 do
  local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
  R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav')))
  R.SetMediaItemInfo_Value(item,'D_POSITION',i*8);R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
  R.SetMediaItemInfo_Value(item,'D_VOL',i==1 and .2 or .1)
  R.SetMediaItemInfo_Value(item,'D_FADEINLEN',0);R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
 end
 session=B.begin(job,{0,24})
 check(B.inspect(session).tracks[1].playing_items_in_passage==3,'Leveling targets include the three playing phrases in scope')
 check(B.inspect({project=project,bounds={25,28},owned={}}).tracks[1].playing_items_in_passage==0,'Clips outside the selected passage are not leveling targets')
 J.write(job..'/config.json',{bounds={0,24},visual_analysis=false,rounds=4})
 R.ExecProcess('/usr/bin/python3 -B "'..root..'/Mix/test_native_leveling.py" "'..job..'"',-1)
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
   check(result.ok,'Worker measured and corrected the loud phrase: '..tostring(result.error or 'ok'))
   check(result.before_spread_db>5.8 and result.after_spread_db<.3,'Rendered level spread fell from 6 dB to below 0.3 dB')
   local tr=R.GetTrack(project,0);local guid=R.GetTrackGUID(tr)
   check(R.TrackFX_GetCount(tr)==1 and session.renders==4,'One reusable trim processor; unchanged evidence reuses cached renders')
   local recovered=B.recover(job);local info=B.execute(recovered,'inspect_project',{})
   check(#info.trim_envelopes==1 and #info.trim_envelopes[1].points==6 and info.trim_envelopes[1].points[3].db<-6,'Recovered session exposes the existing rides in actual dB and project seconds')
   session=recovered
   local points=J.array()
   for i=0,99 do points[#points+1]={seconds=24*i/99,db=(i==0 or i==99)and 0 or 6}end
   B.execute(session,'set_trim_automation',{track=guid,points=points})
   local readback=B.execute(session,'inspect_project',{}).trim_envelopes[1].points
   check(#readback==100 and math.abs(readback[2].db-6)<1e-8 and R.TrackFX_GetCount(tr)==1,'Long envelopes and +6 dB quiet-phrase rides reuse the owned processor')
   points[2].db=7
   check(not pcall(B.execute,session,'set_trim_automation',{track=guid,points=points}),'Out-of-range rides are rejected before replacing the envelope')
   B.compare(session,'original');check(not R.TrackFX_GetEnabled(tr,0),'Original bypasses the level rides')
   B.compare(session,'candidate');check(R.TrackFX_GetEnabled(tr,0),'Candidate restores the level rides')
   B.revert(session);session=nil
   check(R.TrackFX_GetCount(tr)==0 and R.GetMediaTrackInfo_Value(tr,'D_VOL')==1,'Revert removes the trim and preserves the original fader')
   for i=0,2 do check(R.GetMediaItemInfo_Value(R.GetTrackMediaItem(tr,i),'D_VOL')==(i==1 and .2 or .1),'Source clip '..(i+1)..' gain is untouched')end
   done=true;return
  end
  assert(R.time_precise()<deadline,'Native leveling worker timed out')
 end,debug.traceback)
 if not good or done then cleanup(good,why)else R.defer(tick)end
end
tick()
