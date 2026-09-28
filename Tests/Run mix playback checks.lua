-- Native live A/B test in an isolated project with synthetic audio and no hardware sends.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local root=dir:match('^(.*)/Tests$');local R=reaper
local B=dofile(root..'/Scripts/solo_mix_bridge.lua')
assert(R.GetPlayState()==0,'Stop transport before testing.')
local original=R.EnumProjects(-1,'');local original_count=R.GetProjectStateChangeCount(original)
local log=assert(io.open(dir..'/mix-playback-checks.txt','w'));local passed=0
local function check(ok,label)assert(ok,label);passed=passed+1;log:write('PASS '..label..'\n');log:flush()end
R.Main_OnCommand(41929,0);local project=R.EnumProjects(-1,'')
local s,tr,start_time,last_position,step,test_plugin;local finished=false
local function cleanup(err)
 if finished then return end;finished=true
 if R.EnumProjects(-1,'')~=project then R.SelectProjectInstance(project)end
 R.OnStopButton()
 if s and not s.finished then pcall(B.revert,s)end
 R.Main_SaveProjectEx(project,dir..'/Mix playback checks.RPP',8)
 R.Main_OnCommand(40860,0);R.SelectProjectInstance(original)
 if not err then check(R.GetProjectStateChangeCount(original)==original_count,'Original user project unchanged')end
 if err then log:write('FAIL '..err..'\n')end
 log:write(passed..' native playback checks passed\n');log:close()
 if err then R.ShowMessageBox(err,'Mix playback checks',0)end
end
local ok,err=xpcall(function()
 R.InsertTrackAtIndex(0,false);tr=R.GetTrack(project,0)
 local master=R.GetMasterTrack(project)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Test has no hardware outputs')
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(dir..'/mix-tone.wav')))
 R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 R.SetEditCurPos2(project,0,false,false)
 local path=dir..'/Mix test data/playback-'..R.genGuid():gsub('[^%w]','')
 R.RecursiveCreateDirectory(path,0);s=B.begin(path,{0,8})
 B.execute(s,'set_track_mix',{track=R.GetTrackGUID(tr),volume_db=-6,pan=.25})
 for _,name in ipairs(B.plugins())do if name:find('ReaComp',1,true)then test_plugin=name;break end end
 B.execute(s,'add_effect',{track=R.GetTrackGUID(tr),plugin=assert(test_plugin)})
 start_time=R.time_precise();last_position=0;step=0;R.OnPlayButton()
end,debug.traceback)
if not ok then cleanup(err);return end
local function tick()
 local good,why=xpcall(function()
  assert(R.EnumProjects(-1,'')==project,'Test project changed')
  assert(R.time_precise()-start_time<6,'Playback did not advance; check the audio device')
  if R.GetPlayPosition()<.15*(step+1)then R.defer(tick);return end
  check(R.GetPlayState()==1,'Transport playing before switch '..step)
  local position=R.GetPlayPosition();check(position>last_position,'Playhead advances before switch '..step)
  log:write('STATE '..s.version..' -> '..R.GetProjectStateChangeCount(project)..'\n');log:flush()
  if step<6 then
   local mode=step%2==0 and 'original'or 'candidate'
   B.compare(s,mode)
   check(R.GetPlayState()==1 and R.GetPlayPosition()>=position and R.GetCursorPosition()==0,'A/B leaves playback and cursor uninterrupted: '..mode)
   check(R.TrackFX_GetEnabled(tr,0)==(mode=='candidate'),'A/B switches actual plugin bypass: '..mode)
  elseif step==6 then
   B.keep(s);check(s.finished and R.GetPlayState()==1,'Keep accepts candidate during playback')
   R.OnStopButton();local path=s.path..'/revert';R.RecursiveCreateDirectory(path,0);s=B.begin(path,{0,8})
   B.execute(s,'set_track_mix',{track=R.GetTrackGUID(tr),volume_db=-9,pan=-.25})
   B.execute(s,'add_effect',{track=R.GetTrackGUID(tr),plugin=test_plugin})
   R.OnPlayButton();last_position=0;step=7;start_time=R.time_precise();R.defer(tick);return
  else
   B.revert(s)
   check(s.finished and R.GetPlayState()==1 and R.TrackFX_GetCount(tr)==1,'Revert restores prior candidate and removes only new FX while playing')
   cleanup();return
  end
  last_position=position;step=step+1;R.defer(tick)
 end,debug.traceback)
 if not good then cleanup(why)end
end
R.defer(tick)
