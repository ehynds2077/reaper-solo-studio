-- Real render/worker/analyzer/engine recovery with one injected silent WAV.
-- Only the second render in a disposable, inaudible project is substituted.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local J=B.json
local log=assert(io.open(root..'/Tests/render-recovery-checks.txt','w'))
if R.GetExtState('SoloStudio_v1','panel_open')=='1'or R.GetAllProjectPlayStates()~=0 then
 log:write('NOT RUN: Close Solo Studio and stop all transport first.\n');log:close();return
end
local original=R.EnumProjects(-1,'');local chunks={};local count=R.CountTracks(original)
for i=-1,count-1 do
 local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i)
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok);chunks[i]=chunk
end
local project,session,job;local passed=0;local resets=0;local renders=0
local native_command=R.Main_OnCommand
local function check(v,label)assert(v,label);passed=passed+1;log:write('PASS: '..label..'\n');log:flush()end
local function cleanup(ok,err)
 R.Main_OnCommand=native_command
 if session then pcall(B.revert,session)end
 if project and R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,job..'/Recovery checks.RPP',8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 local preserved=R.CountTracks(original)==count
 for i=-1,count-1 do
  local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i)
  local good,chunk=R.GetTrackStateChunk(tr,'',false);preserved=preserved and good and chunks[i]==chunk
 end
 log:write(preserved and 'PASS: Original track and master contents preserved exactly\n'or 'FAIL: Original contents changed\n')
 log:write(ok and (passed..' native recovery checks passed\n')or ('FAIL: '..tostring(err)..'\n'));log:close()
 dofile(root..'/Launcher/launch.lua')
end
local ok,err=xpcall(function()
 job=root..'/Tests/Render recovery data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/Recovery checks.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/Recovery checks.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Disposable project has no hardware outputs')
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(project,0)
 R.GetSetMediaTrackInfo_String(tr,'P_NAME','Synthetic recovery tone',true);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0)
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav')))
 R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 session=B.begin(job,{0,8});J.write(job..'/config.json',{bounds={0,8},visual_analysis=false,rounds=3})
 R.Main_OnCommand=function(command,flag)
  if command~=42230 then return native_command(command,flag)end
  renders=renders+1
  if renders~=2 then return native_command(command,flag)end
  local _,path=R.GetSetProjectInfo_String(project,'RENDER_FILE','',false)
  local _,pattern=R.GetSetProjectInfo_String(project,'RENDER_PATTERN','',false)
  local bytes=8*48000*6;local wav=assert(io.open(path..'/'..pattern..'.wav','wb'))
  wav:write('RIFF'..string.pack('<I4',bytes+36)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,2,48000,48000*6,6,24)..'data'..string.pack('<I4',bytes))
  wav:write(string.rep('\0',bytes));wav:close()
 end
 R.ExecProcess('/usr/bin/python3 -B "'..root..'/Mix/test_native_render_recovery.py" "'..job..'"',-1)
end,debug.traceback)
if not ok then cleanup(false,err);return end
local handled='';local deadline=R.time_precise()+120
local function tick()
 local done=false
 local good,why=xpcall(function()
  local request=J.read(job..'/request.json')
  if request and request.id~=handled then
   handled=request.id
   if request.name=='recover_silent_render'then resets=resets+1 end
   local accepted,result=pcall(B.execute,session,request.name,request.arguments)
   J.write(job..'/response-'..request.id..'.json',accepted and {result=result}or {error=tostring(result),fatal=true})
  end
  local result=J.read(job..'/test-result.json')
  if result then
   check(result.ok,'Worker recovered to measured review: '..tostring(result.error or 'valid output'))
   check(resets==1 and renders==3,'Exactly one engine restart and three renders including original')
   check(R.Audio_IsRunning()~=0,'Audio engine running after recovery')
   local cached=0;for _ in pairs(session.render_cache)do cached=cached+1 end
   check(cached==1,'Only the successful retry remains in render cache')
   check(math.abs(R.GetMediaTrackInfo_Value(R.GetTrack(project,0),'D_VOL')-10^(-3/20))<1e-8,'Recovery preserved candidate fader')
   done=true;return
  end
  assert(R.time_precise()<deadline,'Native recovery worker timed out')
 end,debug.traceback)
 if not good or done then cleanup(good,why)else R.defer(tick)end
end
tick()
