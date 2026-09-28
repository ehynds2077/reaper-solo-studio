-- Temporarily disable native pre-roll when recording already starts two bars early.
-- Journal restoration independently of the panel and preserve manual setting changes.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
local H={ns='SoloStudio_v1',key='section.capture_settings',field='P_EXT:SoloStudioRecordingBounds'}
local function global_job()local ok,v=pcall(J.decode,R.GetExtState(H.ns,'capture.global'));if ok and type(v)=='table'then return v end end
function H.tag_item(it,capture)
 local take=R.GetActiveTake(it);if not take or R.TakeIsMIDI(take)then return false end
 local src=R.GetMediaItemTake_Source(take);local length,qn=R.GetMediaSourceLength(src);if qn then return false end
 local pos=R.GetMediaItemInfo_Value(it,'D_POSITION');local offset=R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS');local rate=R.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE')
 local low=math.max(0,offset+(capture.first-pos)*rate);local high=math.min(length,offset+(capture.last-pos)*rate)
 if high<=low then return false end
 local data={version=1,low=low,high=high,file=R.GetMediaSourceFileName(src,'')}
 return R.GetSetMediaItemInfo_String(it,H.field,J.encode(data),true)
end
function H.bounds(it,src)
 local _,raw=R.GetSetMediaItemInfo_String(it,H.field,'',false);local ok,v=pcall(J.decode,raw)
 if ok and type(v)=='table'and v.version==1 and type(v.low)=='number'and type(v.high)=='number'and v.low>=0 and v.high>v.low and v.file==R.GetMediaSourceFileName(src,'')then return v.low,v.high end
end
function H.job(project)
 local _,raw=R.GetProjExtState(project,H.ns,H.key);local ok,job=pcall(J.decode,raw)
 if ok and type(job)=='table'and type(job.token)=='string'and R.GetExtState(H.ns,'capture.completed.'..job.token)~='1'then return job end
end
function H.restore(project,token)
 local valid=R.ValidatePtr(project,'ReaProject*');local global=global_job()
 local job=valid and H.job(project)or global and global.project==tostring(project)and global
 if not job or token and job.token~=token then return end
 if (not global or global.token==job.token)and R.GetToggleCommandStateEx(0,41819)==job.applied_preroll and job.preroll~=job.applied_preroll then R.Main_OnCommandEx(41819,0,valid and project or 0)end
 if valid and job.loop then
  local a,b=R.GetSet_LoopTimeRange2(project,false,true,0,0,false)
  if math.abs(a-job.first)<0.00001 and math.abs(b-job.last)<0.00001 then R.GetSet_LoopTimeRange2(project,true,true,job.loop[1],job.loop[2],false)end
 end
 if (not global or global.token==job.token)and job.linked==1 and R.GetToggleCommandStateEx(0,40621)==0 then R.Main_OnCommandEx(40621,0,valid and project or 0)end
 R.SetExtState(H.ns,'capture.completed.'..job.token,'1',false)
 if valid then R.SetProjExtState(project,H.ns,H.key,'')end
 if global and global.token==job.token then R.DeleteExtState(H.ns,'capture.global',false)end
end
function H.prepare(project,first,last,punch,looping)
 H.restore(project)
 local a,b=R.GetSet_LoopTimeRange2(project,false,true,0,0,false)
 local job={token=R.genGuid(),project=tostring(project),preroll=R.GetToggleCommandStateEx(0,41819),applied_preroll=punch==0 and 1 or 0,
  first=first,last=last,linked=looping and R.GetToggleCommandStateEx(0,40621)or nil,loop=looping and {a,b}or nil}
 R.SetProjExtState(project,H.ns,H.key,J.encode(job))
 R.SetExtState(H.ns,'capture.global',J.encode(job),false)
 if job.preroll~=job.applied_preroll then R.Main_OnCommandEx(41819,0,project)end
 if job.linked==1 then R.Main_OnCommandEx(40621,0,project)end
 if looping then R.GetSet_LoopTimeRange2(project,true,true,first,last,false)end
 return job
end
function H.recover(project)
 if R.GetPlayStateEx(project)&4==0 then H.restore(project)end
end
return H
