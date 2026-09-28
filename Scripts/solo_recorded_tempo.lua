-- Recording provenance belongs to the clip, not to the current project tempo.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
return function(M)
 local Q={field='P_EXT:SoloStudioRecordedTempo',job_key='recorded_tempo.job'}
 local function str(it,key)local _,s=R.GetSetMediaItemInfo_String(it,key,'',false);return s end
 local function finite(v)return type(v)=='number'and v==v and v>0 and v<math.huge end
 local function decode(s)local ok,v=pcall(J.decode,s);if ok and type(v)=='table'and v.version==1 then return v end end
 function Q.read(it)
  local v=decode(str(it,Q.field))
  if v and finite(v.bpm)and (v.kind=='constant'or v.kind=='map')then return v end
 end
 function Q.format(bpm)return string.format('%.2f',bpm):gsub('0+$',''):gsub('%.$','')end
 function Q.snapshot(project)
  local _,_,bpm=R.TimeMap_GetTimeSigAtTime(project,0)
  assert(finite(bpm),'Could not read the recording tempo.')
  local data={version=1,kind='constant',bpm=bpm,source='recorded'}
  if R.CountTempoTimeSigMarkers(project)>0 then
   data.kind='map';data.markers=J.array()
   for i=0,R.CountTempoTimeSigMarkers(project)-1 do
    local ok,t,_,_,b,n,d,linear=R.GetTempoTimeSigMarker(project,i);assert(ok,'Could not read the tempo map.')
    data.markers[#data.markers+1]={time=t,bpm=b,numerator=n,denominator=d,linear=linear}
   end
  end
  return data
 end
 function Q.label(v)
  if not v then return 'Tempo ?'end
  if v.changed then return 'Tempo changed'end
  return v.kind=='map'and 'Tempo map'or Q.format(v.bpm)..' BPM'
 end
 function Q.describe(items,project)
  local first;local missing=false;local mixed=false;local clips={}
  for _,it in ipairs(items)do
   local v=Q.read(it)
   clips[it]=Q.label(v)
   if not v then missing=true
   elseif not first then first=v
   elseif J.encode(first)~=J.encode(v)then
    -- Manually labelled and automatically captured clips may share one BPM.
    if first.kind~='constant'or v.kind~='constant'or first.changed or v.changed or math.abs(first.bpm-v.bpm)>0.005 then mixed=true end
   end
  end
  if not first then return {label='Tempo ?',unknown=true,clips=clips}end
  if missing or mixed then return {label='Mixed tempo',unknown=missing,mixed=true,clips=clips}end
  local different=false
  if first.kind=='constant'and not first.changed and R.CountTempoTimeSigMarkers(project or 0)==0 then
   local _,_,current=R.TimeMap_GetTimeSigAtTime(project or 0,0)
   different=math.abs(first.bpm-current)>0.005
  end
  return {label=Q.label(first),bpm=first.kind=='constant'and not first.changed and first.bpm or nil,different=different,clips=clips}
 end
 function Q.job(project)
  local _,raw=R.GetProjExtState(project,M.ns,Q.job_key);local job=decode(raw)
  if job and type(job.tracks)=='table'and type(job.tempo)=='table'and finite(job.tempo.bpm)and type(job.token)=='string'and type(job.started)=='number'and R.GetExtState(M.ns,'tempo.completed.'..job.token)~='1'then return job end
 end
 local function save(project,job)R.SetProjExtState(project,M.ns,Q.job_key,job and J.encode(job)or '')end
 function Q.finish(project,token)
  if not R.ValidatePtr(project,'ReaProject*')or R.GetPlayStateEx(project)&4~=0 then return false end
  local job=Q.job(project);if not job or token and job.token~=token then return false end
  local data=J.encode(job.tempo);local changed=false
  for i=0,R.CountTracks(project)-1 do
   local tr=R.GetTrack(project,i);local before=job.tracks[R.GetTrackGUID(tr)]
   if before then for j=0,R.CountTrackMediaItems(tr)-1 do
    local it=R.GetTrackMediaItem(tr,j)
    if not before[str(it,'GUID')]and str(it,'P_EXT:SoloStudioPreview')==''and str(it,Q.field)==''then
     assert(R.GetSetMediaItemInfo_String(it,Q.field,data,true),'Could not save a recorded tempo.');changed=true
    end
   end end
  end
  R.SetExtState(M.ns,'tempo.completed.'..job.token,'1',false)
  save(project,nil)
  if changed then
   R.MarkProjectDirty(project);R.UpdateTimeline()
   -- Capture the new metadata before a later edit creates its undo baseline.
   R.Undo_OnStateChangeEx2(project,'Solo Studio: store recorded tempo',4,-1)
  end
  return true
 end
 function Q.begin(project,tracks)
  Q.finish(project)
  local job={version=1,token=R.genGuid(),tempo=Q.snapshot(project),tracks={},started=R.time_precise()}
  for _,tr in ipairs(tracks)do
   local before={};for i=0,R.CountTrackMediaItems(tr)-1 do before[str(R.GetTrackMediaItem(tr,i),'GUID')]=true end
   job.tracks[R.GetTrackGUID(tr)]=before
  end
  save(project,job);return job.token
 end
 function Q.observe(project,job)
  local dirty=not job.seen;job.seen=true
  if not job.tempo.changed and J.encode(Q.snapshot(project))~=J.encode(job.tempo)then job.tempo.changed=true;dirty=true end
  if dirty then save(project,job)end
 end
 function Q.discard(project,token)
  local job=Q.job(project);if job and job.token==token then R.SetExtState(M.ns,'tempo.completed.'..job.token,'1',false);save(project,nil)end
 end
 function Q.watch()
  local command=R.AddRemoveReaScript(true,0,dir..'/Solo Studio - Store recording tempo.lua',true)
  assert(command~=0,'Could not start the recorded-tempo helper.')
  R.Main_OnCommand(command,0)
 end
 function Q.assign(rows,bpm)
  M.stopped();M.cancel_preview();M.finish_recorded_tempo()
  assert(finite(bpm)and bpm>=1 and bpm<=960,'Enter the known recording tempo from 1 to 960 BPM.')
  assert(#rows>0,'Select at least one source take.')
  local tracks=M.require_tracks();local changes={};local seen={}
  for _,row in ipairs(rows)do
   local live=M.row_for_lane(row.lane)
   assert(live and live.key==row.key and not live.is_comp and not live.is_preview,'A selected take changed. Select it again.')
   M.validate_lane(tracks,row.lane)
   for _,tr in ipairs(tracks)do for _,it in ipairs(M.lane_items(tr,row.lane))do
    if not seen[it]then changes[#changes+1]={item=it,before=str(it,Q.field)};seen[it]=true end
   end end
  end
  local value=J.encode({version=1,kind='constant',bpm=bpm,source='manual'})
  M.edit('label recorded tempo',function()
   local ok,err=pcall(function()for _,c in ipairs(changes)do assert(R.GetSetMediaItemInfo_String(c.item,Q.field,value,true),'Could not label the recorded tempo.')end end)
   if not ok then for _,c in ipairs(changes)do R.GetSetMediaItemInfo_String(c.item,Q.field,c.before,true)end;error(err,0)end
  end)
 end
 return Q
end
