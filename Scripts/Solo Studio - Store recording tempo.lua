-- Independent of the panel: follow full-song, section and loop recordings.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local Q=dofile(dir..'/solo_recorded_tempo.lua')({ns='SoloStudio_v1'})
if R.set_action_options then R.set_action_options(3)end
local last=0
local function poll()
 local now=R.time_precise()
 if now-last<0.1 then R.defer(poll);return end
 last=now;local pending=false
 local i=0
 while true do
  local project=R.EnumProjects(i,'');if not project then break end;i=i+1
  local job=Q.job(project)
  if job then
   if R.GetPlayStateEx(project)&4~=0 then Q.observe(project,job);pending=true
   elseif job.seen then if not Q.finish(project,job.token)then pending=true end
   elseif now-job.started>120 then Q.discard(project,job.token)
   else pending=true end
  end
 end
 if pending then R.defer(poll)end
end
poll()
