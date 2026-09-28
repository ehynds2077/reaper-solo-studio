-- A silent, monitor-only helper for hardware-monitored recording sessions.
local R=reaper
local T={fxname='Solo Studio/Solo Studio Strobe.jsfx',ns='SoloStudioTuner_v1'}
local function str(tr,key,value)
 local _,s=R.GetSetMediaTrackInfo_String(tr,key,value or '',value~=nil);return s
end
local function ishelper(tr) return str(tr,'P_EXT:SoloStudioTuner')=='1' end
function T.prepare(source,input)
 assert(R.GetPlayState()&4==0,'Stop recording before opening the tuner.')
 local project=R.EnumProjects(-1,'')
 assert(source and R.ValidatePtr2(project,source,'MediaTrack*'),'Select your guitar or bass track first.')
 assert(not ishelper(source),'Select the instrument track, then open Tuner.')
 assert(input and input%1==0 and input>=0 and input<R.GetNumAudioInputs(),'Choose an available audio input for the tuner.')
 local helper
 for i=0,R.CountTracks(project)-1 do local tr=R.GetTrack(project,i);if ishelper(tr) then helper=tr;break end end
 assert(not helper or R.CountTrackMediaItems(helper)==0,'The Solo Studio tuner track contains media. Move that media before reusing it for tuning.')
 R.Undo_BeginBlock2(project)
 local ok,result=xpcall(function()
  if not helper then
   R.InsertTrackAtIndex(R.CountTracks(project),false);helper=R.GetTrack(project,R.CountTracks(project)-1)
   str(helper,'P_EXT:SoloStudioTuner','1')
  end
  R.SetMediaTrackInfo_Value(helper,'I_RECARM',0)
  R.SetMediaTrackInfo_Value(helper,'B_AUTO_RECARM',0)
  R.SetMediaTrackInfo_Value(helper,'B_MAINSEND',0)
  for _,category in ipairs({0,1}) do
   for i=R.GetTrackNumSends(helper,category)-1,0,-1 do R.RemoveTrackSend(helper,category,i) end
  end
  R.SetMediaTrackInfo_Value(helper,'I_RECMODE',2) -- monitor only; never records media
  R.SetMediaTrackInfo_Value(helper,'I_RECINPUT',input)
  R.SetMediaTrackInfo_Value(helper,'I_RECMON',1)
  R.SetMediaTrackInfo_Value(helper,'B_MUTE',0)
  R.SetMediaTrackInfo_Value(helper,'I_SOLO',0)
  R.SetMediaTrackInfo_Value(helper,'I_NCHAN',2)
  R.SetMediaTrackInfo_Value(helper,'D_VOL',1)
  str(helper,'P_NAME','Tuner - '..str(source,'P_NAME')..' (silent)')
  str(helper,'P_EXT:SoloStudioTunerSource',R.GetTrackGUID(source))
  local fx=R.TrackFX_AddByName(helper,T.fxname,false,1)
  assert(fx>=0,'Install Solo Studio Strobe.jsfx in REAPER/Effects/Solo Studio first.')
  R.TrackFX_SetEnabled(helper,fx,true)
  R.TrackFX_SetOffline(helper,fx,false)
  R.TrackFX_SetParam(helper,fx,3,0) -- mono input is duplicated to L/R; detect left
  R.TrackFX_SetParam(helper,fx,5,1) -- output mute, in addition to absent sends
  R.TrackList_AdjustWindows(false)
  return fx
 end,debug.traceback)
 R.Undo_EndBlock2(project,'Solo Studio: prepare silent tuner',-1)
 if not ok then if helper then R.SetMediaTrackInfo_Value(helper,'I_RECARM',0) end;error(result,0) end
 return helper,result,project
end

function T.open()
 assert(R.GetPlayState()&4==0,'Stop recording before opening the tuner.')
 local source=R.GetSelectedTrack(0,0)
 if not source or ishelper(source) or R.CountSelectedTracks(0)~=1 then
  local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
  local M=dofile(dir..'/solo_core.lua');source=M.tracks()[1]
 end
 assert(source and not ishelper(source),'Select your guitar or bass track first.')
 local count=R.GetNumAudioInputs()
 assert(count>0,'Connect the X32 and choose its audio device in REAPER Settings first.')
 local input=math.floor(R.GetMediaTrackInfo_Value(source,'I_RECINPUT'))
 if input>=0 and input<4096 then input=input&1023 end
 if input<0 or input>=count then
  -- Remember a tuner-only input separately; never change the recording track.
  local previous=str(source,'P_EXT:SoloStudioTunerInput')
  local ok,value=R.GetUserInputs('Tuner input for '..str(source,'P_NAME'),1,
   'X32 USB input number (1-'..count..'):,extrawidth=140',previous)
  if not ok then return end
  local onebased=tonumber(value)
  assert(onebased and onebased%1==0 and onebased>=1 and onebased<=count,'Enter an input number from 1 to '..count..'.')
  input=onebased-1;str(source,'P_EXT:SoloStudioTunerInput',tostring(onebased))
 end
 local helper,fx,project=T.prepare(source,input)
 local key=R.GetTrackGUID(helper);local token=tostring(R.time_precise())
 R.SetExtState(T.ns,key,token,false)
 R.SetMediaTrackInfo_Value(helper,'I_RECARM',1)
 R.TrackFX_Show(helper,fx,3)
 local fxguid=R.TrackFX_GetFXGUID(helper,fx)
 local function owned()
  return R.ValidatePtr(project,'ReaProject*') and R.ValidatePtr2(project,helper,'MediaTrack*') and R.GetExtState(T.ns,key)==token
 end
 local function cleanup()
  if owned() then
   R.SetMediaTrackInfo_Value(helper,'I_RECARM',0)
   R.SetExtState(T.ns,key,'',false)
  end
 end
 R.atexit(cleanup)
 local function watch()
  if not owned() then return end
  if R.EnumProjects(-1,'')~=project or R.GetPlayStateEx(project)&4~=0 then cleanup();return end
  local currentfx=-1
  for i=0,R.TrackFX_GetCount(helper)-1 do if R.TrackFX_GetFXGUID(helper,i)==fxguid then currentfx=i;break end end
  if currentfx<0 or not R.TrackFX_GetFloatingWindow(helper,currentfx) then cleanup();return end
  R.defer(watch)
 end
 R.defer(watch)
 return helper,fx
end
return T
