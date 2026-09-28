-- Roll/trim comp item edges without moving source audio or song regions.
-- Bounds come from the actual media, so old takes expose only real handles.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local H=dofile(dir..'/solo_recording_handles.lua')
return function(M)
 local B={};local epsilon=0.00001;local minimum=0.001
 local function str(it,key)local _,value=R.GetSetMediaItemInfo_String(it,key,'',false);return value end
 local function info(it)
  local s=R.GetMediaItemInfo_Value(it,'D_POSITION');local e=s+R.GetMediaItemInfo_Value(it,'D_LENGTH')
  local take=R.GetActiveTake(it);local low,high=s,e;local rate,offset
  if take and not R.TakeIsMIDI(take)and R.GetTakeNumStretchMarkers(take)==0 and R.CountTakeEnvelopes(take)==0 then
   local src=R.GetMediaItemTake_Source(take);local length,qn=R.GetMediaSourceLength(src)
   rate=R.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE');offset=R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')
   -- Section/reversed sources retain their own media bounds; never read past them.
   if not qn and rate>0 and length>0 and offset>=0 and offset<=length and offset+(e-s)*rate<=length+epsilon then
    local first,last=H.bounds(it,src);first=math.max(0,first or 0);last=math.min(length,last or length)
    low=math.max(0,s+(first-offset)/rate);high=s+(last-offset)/rate
   else rate=nil end
  end
  return {item=it,key=str(it,'GUID'),source=str(it,'P_EXT:SoloStudioSource'),s=s,e=e,low=low,high=high,take=take,rate=rate,offset=offset}
 end
 local function items(tr)
  local lane=M.comp_lane(tr);local out={}
  if lane then for _,it in ipairs(M.lane_items(tr,lane))do out[#out+1]=info(it)end end
  return out,lane
 end
 local function edges(list)
  local out={}
  for i,it in ipairs(list)do
   local prev,next=list[i-1],list[i+1]
   if not prev or it.s>prev.e+epsilon then
    out[#out+1]={key=it.key..':s',kind='s',right=it,pos=it.s,low=math.max(it.low,prev and prev.e or 0),high=it.e-minimum}
   end
   if next and next.s<=it.e+epsilon then
    if next.s>it.s and next.e>it.e then
     local half=math.max(0,it.e-next.s)/2
     out[#out+1]={key=it.key..':'..next.key,kind='roll',left=it,right=next,pos=(it.e+next.s)/2,half=half,
      low=math.max(it.s+minimum-half,next.low+half),high=math.min(it.high-half,next.e-minimum+half)}
    end
   else
    out[#out+1]={key=it.key..':e',kind='e',left=it,pos=it.e,low=it.s+minimum,high=math.min(it.high,next and next.s or math.huge)}
   end
  end
  return out
 end
 function B.list()
  local tracks=M.tracks();if #tracks==0 then return {}end
  local list=items(tracks[1]);return edges(list)
 end
 local function signature(tracks)
  local parts={}
  for _,tr in ipairs(tracks)do
   local list,lane=items(tr);parts[#parts+1]=R.GetTrackGUID(tr)..':'..tostring(lane)
   for _,it in ipairs(list)do parts[#parts+1]=table.concat({it.key,it.source,it.s,it.e,it.low,it.high,it.offset or '',it.rate or ''},':')end
  end
  return table.concat(parts,'|')
 end
 function B.plan(key,position,expected)
  M.stopped();local tracks=M.require_tracks();local current=signature(tracks)
  assert(not expected or expected==current,'The comp changed while dragging. Try the edge again.')
  local first=edges(items(tracks[1]));local index,edge
  for i,candidate in ipairs(first)do if candidate.key==key then index=i;edge=candidate;break end end
  assert(edge,'This comp edge changed. Select it again.')
  local low,high=edge.low,edge.high;local matched={}
  for _,tr in ipairs(tracks)do
   local list,lane=items(tr);local all=edges(list);local other=all[index]
   assert(lane==M.comp_lane(tracks[1])and #all==#first and other and other.kind==edge.kind and math.abs(other.pos-edge.pos)<epsilon,
    'The comp boundaries do not match across microphones. Align them before dragging.')
   for _,side in ipairs({'left','right'})do if edge[side]then
    local a,b=edge[side],other[side]
    assert(b and math.abs(a.s-b.s)<epsilon and math.abs(a.e-b.e)<epsilon and a.source==b.source,'The comp passages do not match across microphones.')
    assert(b.take and b.rate,'This comp uses looped, stretched, MIDI, or take-envelope audio. Edit its edges in REAPER.')
   end end
   low=math.max(low,other.low);high=math.min(high,other.high);matched[#matched+1]={track=tr,edge=other}
  end
  assert(low<=high,'There is no shared audio available at this comp edge.')
  local pos=position or edge.pos
  assert(type(pos)=='number'and pos==pos and pos>=low-epsilon and pos<=high+epsilon,'That edge exceeds the audio available on one or more microphones.')
  pos=math.max(low,math.min(high,pos));local changes={}
  for _,pair in ipairs(matched)do
   local e=pair.edge
   if e.left then changes[#changes+1]={track=pair.track,clip=e.left,s=e.left.s,e=pos+(e.half or 0)}end
   if e.right then changes[#changes+1]={track=pair.track,clip=e.right,s=pos-(e.half or 0),e=e.right.e}end
  end
  return {key=key,kind=edge.kind,pos=pos,original=edge.pos,low=low,high=high,signature=current,changes=changes}
 end
 function B.move(key,position,expected)
  local plan=B.plan(key,position,expected)
  if math.abs(plan.pos-plan.original)<epsilon then return end
  local snapshots={}
  for _,c in ipairs(plan.changes)do if not snapshots[c.track]then
   local ok,chunk=R.GetTrackStateChunk(c.track,'',false);assert(ok,'Could not prepare an undoable comp-edge edit.');snapshots[c.track]=chunk
  end end
  M.edit('move comp boundary',function()
   local ok,err=xpcall(function()
    for _,c in ipairs(plan.changes)do
     local clip=c.clip;local offset=clip.offset+(c.s-clip.s)*clip.rate
     assert(R.SetMediaItemTakeInfo_Value(clip.take,'D_STARTOFFS',offset),'Could not trim the comp source offset.')
     assert(R.SetMediaItemInfo_Value(clip.item,'D_POSITION',c.s),'Could not set the comp start.')
     assert(R.SetMediaItemInfo_Value(clip.item,'D_LENGTH',c.e-c.s),'Could not set the comp end.')
     R.SetMediaItemInfo_Value(clip.item,'B_LOOPSRC',0)
     assert(math.abs(R.GetMediaItemInfo_Value(clip.item,'D_POSITION')-c.s)<epsilon and math.abs(R.GetMediaItemInfo_Value(clip.item,'D_LENGTH')-(c.e-c.s))<epsilon,'REAPER did not move every comp edge.')
    end
   end,debug.traceback)
   if not ok then
    local restored=true;for tr,chunk in pairs(snapshots)do if not R.SetTrackStateChunk(tr,chunk,false)then restored=false end end
    error(restored and err or 'Comp-edge edit failed and restoration was incomplete. Use REAPER Undo.',0)
   end
  end)
 end
 return B
end
