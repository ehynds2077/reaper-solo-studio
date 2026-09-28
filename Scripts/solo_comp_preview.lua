-- A disposable playback lane: copy the saved comp outside the preview range,
-- and the candidate inside it. Source/comp items are never edited for preview.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
return function(M)
 local P={};local session
 local function str(it,key)local _,v=R.GetSetMediaItemInfo_String(it,key,'',false);return v end
 local function track(project,guid)
  for i=0,R.CountTracks(project)-1 do local tr=R.GetTrack(project,i);if R.GetTrackGUID(tr)==guid then return tr end end
 end
 local function read(project)
  local _,raw=R.GetProjExtState(project,M.ns,'comp.preview');if raw==''then return end
  return J.decode(raw)
 end
 local function write(project,data)R.SetProjExtState(project,M.ns,'comp.preview',data and J.encode(data)or '')end
 function P.current()
  if session and R.EnumProjects(-1,'')==session.project then return session.data end
 end
 function P.cancel(project)
  project=project or R.EnumProjects(-1,'')
  if not R.ValidatePtr(project,'ReaProject*')then if session and session.project==project then session=nil end;return end
  local data=read(project);if not data then if session and session.project==project then session=nil end;return end
  local ok,err=xpcall(function()
   for _,saved in ipairs(data.tracks)do
    local tr=track(project,saved.guid)
    if tr then
     local count=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')
     local playing=count>saved.lane and R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..saved.lane)>0
     -- Only our tagged items are removed, even if somebody edited the track.
     for i=R.CountTrackMediaItems(tr)-1,0,-1 do local it=R.GetTrackMediaItem(tr,i)
      if str(it,'P_EXT:SoloStudioPreview')==data.token then assert(R.DeleteTrackMediaItem(tr,it),'Could not clear a preview item.')end
     end
     if count==saved.lane+1 and #M.lane_items(tr,saved.lane)==0 then
      R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',saved.lane)
     end
     if playing then
      R.SetMediaTrackInfo_Value(tr,'C_ALLLANESPLAY',0)
      for _,old in ipairs(saved.playing)do
       local lane
       for i=0,R.CountTrackMediaItems(tr)-1 do local it=R.GetTrackMediaItem(tr,i)
        if str(it,'GUID')==old.anchor then lane=R.GetMediaItemInfo_Value(it,'I_FIXEDLANE');break end
       end
       if not lane and count==saved.lane+1 then lane=old.lane end
       if lane then R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..lane,2)end
      end
     end
    end
   end
  end,debug.traceback)
  if not ok then error(err,0)end
  write(project,nil);if session and session.project==project then session=nil end
  R.UpdateTimeline()
 end
 local function clone(tr,source,a,b,lane,token)
  local p=R.GetMediaItemInfo_Value(source,'D_POSITION');local q=p+R.GetMediaItemInfo_Value(source,'D_LENGTH')
  a=math.max(a,p);b=math.min(b,q);if b-a<0.00001 then return end
  local ok,chunk=R.GetItemStateChunk(source,'',false);assert(ok,'Could not copy this clip for preview.')
  -- A copied item and its take/FX/envelopes must have fresh identities.
  chunk=chunk:gsub('([^\n]+)',function(line)
   local key=line:match('^%s*(%S+)%s+{[%x%-]+}')
   if key=='GUID'or key=='IGUID'or key=='FXID'or key=='EGUID'then return line:gsub('{[%x%-]+}',function()return R.genGuid()end)end
   return line
  end)
  local it=assert(R.AddMediaItemToTrack(tr),'Could not create the preview clip.')
  if not R.SetItemStateChunk(it,chunk,false)then R.DeleteTrackMediaItem(tr,it);error('Could not create the preview clip.')end
  R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioPreview',token,true)
  R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',lane);R.SetMediaItemInfo_Value(it,'I_GROUPID',0);R.SetMediaItemSelected(it,false)
  if b<q-0.000001 then
   local tail=assert(R.SplitMediaItem(it,b),'Could not trim the preview end.')
   assert(R.DeleteTrackMediaItem(tr,tail),'Could not trim the preview end.')
   R.SetMediaItemInfo_Value(it,'D_FADEOUTLEN',math.min(0.005,(b-a)/2))
  end
  if a>p+0.000001 then
   local right=assert(R.SplitMediaItem(it,a),'Could not trim the preview start.')
   assert(R.DeleteTrackMediaItem(tr,it),'Could not trim the preview start.');it=right
   R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioPreview',token,true)
   R.SetMediaItemInfo_Value(it,'D_FADEINLEN',math.min(0.005,(b-a)/2))
  end
  return it
 end
 function P.start(key,s,e,autoplay)
  M.stopped();P.cancel()
  assert(type(s)=='number'and type(e)=='number'and s==s and e==e and s>=0 and e<math.huge and e-s>0.00001,'Select a clip or section to preview.')
  local row=assert(M.row_for_key(key),'This take changed. Select it again.')
  assert(not row.is_comp and not row.is_preview,'Select a source take to preview.')
  local tracks=M.require_tracks();M.validate_lane(tracks,row.lane,{s,e})
  local project=R.EnumProjects(-1,'');local data={token=R.genGuid(),key=key,name=row.name,s=s,e=e,tracks=J.array()}
  local plans={};local has_comp=M.comp_lane(tracks[1])~=nil
  for _,tr in ipairs(tracks)do
   local lane=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES');local playing=J.array();local base=M.comp_lane(tr)
   assert((base~=nil)==has_comp,'The comp is missing on one microphone. Restore it before previewing.')
   for n=0,lane-1 do if R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..n)>0 then
    local items=M.lane_items(tr,n);playing[#playing+1]={lane=n,anchor=items[1]and str(items[1],'GUID')or ''}
   end end
   if not base then
    assert(#playing<=1,'Choose one playing take before previewing a passage.')
    base=playing[1]and playing[1].lane or row.lane
   end
   data.tracks[#data.tracks+1]={guid=R.GetTrackGUID(tr),lane=lane,playing=playing}
   plans[#plans+1]={track=tr,lane=lane,base=M.lane_items(tr,base),source=M.lane_items(tr,row.lane)}
  end
  -- Journal before mutation, so a saved project can discard a stale preview.
  write(project,data);session={project=project,data=data}
  R.PreventUIRefresh(1)
  local ok,err=xpcall(function()
   for _,plan in ipairs(plans)do
    local tr=plan.track;R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',plan.lane+1)
    for _,it in ipairs(plan.base)do
     clone(tr,it,0,s,plan.lane,data.token);clone(tr,it,e,math.huge,plan.lane,data.token)
    end
    for _,it in ipairs(plan.source)do clone(tr,it,s,e,plan.lane,data.token)end
    R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..plan.lane,'Preview (temporary)',true)
   end
   for _,plan in ipairs(plans)do
    R.SetMediaTrackInfo_Value(plan.track,'C_LANEPLAYS:'..plan.lane,1)
    assert(R.GetMediaTrackInfo_Value(plan.track,'C_LANEPLAYS:'..plan.lane)==1,'Could not preview every microphone together.')
   end
  end,debug.traceback)
  R.PreventUIRefresh(-1);R.UpdateTimeline()
  if not ok then P.cancel(project);error(err,0)end
  if autoplay and R.GetPlayState()&1==0 then R.SetEditCurPos2(0,s,false,false);R.OnPlayButton()end
  session.version=R.GetProjectStateChangeCount(project)
  return data
 end
 function P.poll()
  if not session then return end
  local p=session.project
  if not R.ValidatePtr(p,'ReaProject*')then session=nil;return end
  local state=R.GetPlayStateEx(p)
  local version=R.GetProjectStateChangeCount(p)
  if R.EnumProjects(-1,'')~=p or state==0 or state&4~=0 or version~=session.version then
   local reason='state='..state..', version='..version..', previous='..session.version
   P.cancel(p);return true,reason
  end
 end
 function P.close()if session then P.cancel(session.project)end end
 return P
end
