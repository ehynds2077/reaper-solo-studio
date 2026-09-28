local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local R=reaper
local preview=io.open(dir..'/preview.flag','r')
if preview then preview:close();dofile(dir..'/Preview.lua');return end
local integration=io.open(dir..'/integration.flag','r')
if integration then integration:close();dofile(dir..'/Integration.lua');return end
local phase=io.open(dir..'/phase.flag','r')
if phase then phase:close() end
local active,active_path=R.EnumProjects(-1,'')
if active_path==dir..'/Tuner checks.rpp' then
 R.Main_SaveProjectEx(active,active_path,8)
 R.Main_OnCommand(40860,0)
end
local inspect=io.open(dir..'/inspect.flag','r')
if inspect then
 inspect:close()
 R.Main_OnCommand(41929,0)
 R.Main_openProject(dir..'/Tuner checks.rpp')
 R.TrackFX_SetParam(R.GetTrack(0,0),0,5,0)
 R.TrackFX_Show(R.GetTrack(0,0),0,3)
 return
end
assert(R.GetPlayState()==0,'Stop playback before running the isolated tuner tests.')
local original=R.EnumProjects(-1,'')
local log=assert(io.open(dir..'/native-test-status.txt','w'))
local function say(s) log:write(s..'\n');log:flush() end
R.Main_OnCommand(41929,0)
local proj=R.EnumProjects(-1,'')
local ok,err=xpcall(function()
 R.InsertTrackAtIndex(0,false)
 local track=R.GetTrack(0,0)
 R.SetMediaTrackInfo_Value(track,'I_NCHAN',phase and 8 or 4)
 R.SetMediaTrackInfo_Value(track,'I_RECMON',0)
 local master=R.GetMasterTrack(0)
 R.SetMediaTrackInfo_Value(master,'I_NCHAN',phase and 8 or 4)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i) end
 assert(R.GetTrackNumSends(master,1)==0,'Test audio must have no hardware outputs')
 local item=R.AddMediaItemToTrack(track)
 local take=R.AddTakeToMediaItem(item)
 local source=R.PCM_Source_CreateFromFile(dir..(phase and '/phase-stimuli.wav' or '/stimuli.wav'))
 assert(source,'Cannot load test audio')
 local duration=R.GetMediaSourceLength(source)
 R.SetMediaItemTake_Source(take,source)
 R.SetMediaItemInfo_Value(item,'D_LENGTH',duration)
 R.SetMediaItemInfo_Value(item,'D_FADEINLEN',0)
 R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
 local fx=R.TrackFX_AddByName(track,'Solo Studio/Strobe QA.jsfx',false,-1)
 assert(fx>=0,'Cannot load instrumented tuner JSFX')
 R.GetSetProjectInfo(0,'RENDER_SETTINGS',0,true)
 R.GetSetProjectInfo(0,'RENDER_BOUNDSFLAG',0,true)
 R.GetSetProjectInfo(0,'RENDER_STARTPOS',0,true)
 R.GetSetProjectInfo(0,'RENDER_ENDPOS',duration,true)
 R.GetSetProjectInfo(0,'RENDER_CHANNELS',phase and 8 or 4,true)
 R.GetSetProjectInfo(0,'RENDER_TAILFLAG',0,true)
 R.GetSetProjectInfo(0,'RENDER_ADDTOPROJ',0,true)
 R.GetSetProjectInfo(0,'RENDER_DITHER',0,true)
 R.GetSetProjectInfo(0,'RENDER_NORMALIZE',0,true)
 R.GetSetProjectInfo_String(0,'RENDER_FORMAT','ZXZhdxgAAA==',true)
 R.GetSetProjectInfo_String(0,'RENDER_FILE',dir,true)
 local runs={{44100,0,0,'44100-left'},{48000,0,0,'48000-left'},{96000,0,0,'96000-left'},
             {48000,1,0,'48000-right'},{48000,2,0,'48000-sum'}, {48000,0,1,'48000-muted'}}
 if phase then runs={{48000,0,0,'phase-440'},{48000,0,0,'phase-442-locked'}} end
 for _,v in ipairs(runs) do
  R.TrackFX_SetParam(track,fx,3,v[2])
  R.TrackFX_SetParam(track,fx,5,v[3])
  if v[4]=='phase-442-locked' then
   R.TrackFX_SetParam(track,fx,0,442)
   R.TrackFX_SetParam(track,fx,1,1)
   R.TrackFX_SetParam(track,fx,2,40)
  end
  R.GetSetProjectInfo(0,'PROJECT_SRATE',v[1],true)
  R.GetSetProjectInfo(0,'PROJECT_SRATE_USE',1,true)
  R.GetSetProjectInfo(0,'RENDER_SRATE',v[1],true)
  R.GetSetProjectInfo_String(0,'RENDER_PATTERN','result-'..v[4],true)
  say('RENDER '..v[4])
  R.Main_OnCommand(42230,0)
  say('DONE '..v[4])
 end
 R.Main_SaveProjectEx(proj,dir..'/Tuner checks.rpp',8)
 say('ALL RENDERS COMPLETE')
end,debug.traceback)
if not ok then say('FAIL '..err) end
R.Main_SaveProjectEx(proj,dir..'/Tuner checks.rpp',8)
R.Main_OnCommand(40860,0)
R.SelectProjectInstance(original)
log:close()
if not ok then R.ShowMessageBox(err,'Tuner checks',0) end
