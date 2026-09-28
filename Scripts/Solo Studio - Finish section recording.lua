-- Independent of the panel window: finish a single section pass and keep it.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local D=dofile(dir..'/solo_leadin.lua')
local H=dofile(dir..'/solo_recording_handles.lua')
if R.set_action_options then R.set_action_options(3)end -- Restart without a duplicate-script prompt.
local ns='SoloStudio_v1'
local job=R.GetExtState(ns,'section_record_job')
local token,last,first=job:match('([^\t]+)\t([^\t]+)\t?([^\t]*)')
local endpoint=tonumber(last)
local punch=tonumber(first)
if not endpoint then return end
local project=R.EnumProjects(-1,'')
local _,project_token=R.GetProjExtState(project,ns,'section_watch_token')
if project_token~=token then return end
local started=R.time_precise();local seen_recording=false
local heard_leadin=false;local restored=false;local previous_position
local function clear()
 D.restore(project,token);H.restore(project,token)
 if R.GetExtState(ns,'section_record_job')==job then R.DeleteExtState(ns,'section_record_job',false)end
 if R.ValidatePtr(project,'ReaProject*')then
  local _,current=R.GetProjExtState(project,ns,'section_watch_token')
  if current==token then R.SetProjExtState(project,ns,'section_watch_token','')end
 end
end
R.atexit(clear)
local function poll()
 if R.GetExtState(ns,'section_record_job')~=job then clear();return end
 if not R.ValidatePtr(project,'ReaProject*')then clear();return end
 local state=R.GetPlayStateEx(project)
 if state&4~=0 then
  seen_recording=true
  local pos=R.GetPlayPositionEx(project)
  if endpoint<0 and restored and punch and pos<punch-0.00001 and previous_position and pos<previous_position then
   D.begin(project,token,punch);restored=false;heard_leadin=false
  end
  previous_position=pos
  if punch and punch>0 and pos<punch-0.00001 then heard_leadin=true end
  if not restored and punch and punch>=0 and pos>=punch and (heard_leadin or pos>punch+0.02)then
   D.restore(project,token);restored=true
  end
  if endpoint>=0 and pos>=endpoint then
   R.Main_OnCommandEx(40667,0,project);clear();return
  end
 elseif seen_recording or R.time_precise()-started>120 then clear();return end
 R.defer(poll)
end
poll()
