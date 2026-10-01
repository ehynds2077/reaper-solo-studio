-- End-to-end MCP -> panel controls -> worker -> native renders/logs.
-- No model calls; synthetic audio in a disposable project with no outputs.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local J=B.json
local log=assert(io.open(root..'/Tests/mcp-native-checks.txt','w'))
if R.GetExtState('SoloStudio_v1','panel_open')=='1'or R.GetAllProjectPlayStates()~=0 then
 log:write('NOT RUN: Close Solo Studio and stop all transport first.\n');log:close();return
end
local original=R.EnumProjects(-1,'');local chunks={};local count=R.CountTracks(original)
for i=-1,count-1 do local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i);local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok);chunks[i]=chunk end
local project,job,X,C;local original_exec=R.ExecProcess;local original_play=R.GetPlayState;local fake_play=false
local function cleanup(ok,err)
 fake_play=false;R.GetPlayState=original_play;R.ExecProcess=original_exec
 if X then X.close()end;if C then C.close()end
 if project and R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project)
  local s=B.find_session(job..'/sessions');if s then pcall(B.revert,s)end
  R.Main_SaveProjectEx(project,job..'/MCP checks.RPP',8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 local preserved=R.CountTracks(original)==count
 for i=-1,count-1 do local tr=i==-1 and R.GetMasterTrack(original)or R.GetTrack(original,i);local good,chunk=R.GetTrackStateChunk(tr,'',false);preserved=preserved and good and chunk==chunks[i]end
 log:write(preserved and 'PASS: Original tracks and master preserved exactly\n'or 'FAIL: Original contents changed\n')
 log:write(ok and 'PASS: Native MCP start, resume, logs, guard diagnosis and cancellation\n'or ('FAIL: '..tostring(err)..'\n'));log:close()
 dofile(root..'/Launcher/launch.lua')
end
local ok,err=xpcall(function()
 job=root..'/Tests/MCP data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/MCP checks.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/MCP checks.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project);for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(project,0);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0)
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav')));R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 J.write(job..'/connection.json',{connected=true});J.write(job..'/settings.json',{visual_analysis=false,rounds=2})
 R.ExecProcess=function(command,timeout)
  local session_path=command:match('"%-%-session"%s+"([^"]+)"$')
  if session_path then return original_exec('/usr/bin/python3 -B "'..root..'/Tests/mcp-scripted-worker.py" "'..session_path..'"',-1)end
  return original_exec(command,timeout)
 end
 R.GetPlayState=function()return fake_play and 1 or original_play()end
 X=dofile(root..'/Scripts/solo_mix.lua')({ns='SoloStudio_MCP_test'},{colors={}}, {data=job})
 C=dofile(root..'/Scripts/solo_mcp.lua')({status=X.control_status,execute=X.control},job..'/control')
 C.poll()
 original_exec('/opt/homebrew/bin/node "'..root..'/MCP/native-check.mjs" "'..job..'"',-1)
end,debug.traceback)
if not ok then cleanup(false,err);return end
local deadline=R.time_precise()+110
local function tick()
 local done=false
 local good,why=xpcall(function()
  fake_play=R.file_exists(job..'/inject-guard')and not R.file_exists(job..'/release-guard')
  X.poll();C.poll()
  local result=J.read(job..'/test-result.json')
  if result then assert(result.ok,result.error);log:write(result.checks..' native protocol checks passed\n');done=true;return end
  assert(R.time_precise()<deadline,'Native MCP checks timed out')
 end,debug.traceback)
 if not good or done then cleanup(good,why)else R.defer(tick)end
end
tick()
