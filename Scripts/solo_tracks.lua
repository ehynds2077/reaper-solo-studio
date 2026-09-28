-- Project track management. Native GUIDs keep recording sets attached through Undo.
local R=reaper
return function(M)
 local T={}
 local function name(tr,index)local value=M.track_name(tr);return value~=''and value or 'Track '..index end
 function T.list()
  local memberships={}
  for _,set in ipairs(M.sets())do for guid in M.get('set.'..set.id..'.tracks'):gmatch('[^\n]+')do
   memberships[guid]=memberships[guid]or {};table.insert(memberships[guid],set)
  end end
  local rows={};local depth=0
  for i=0,R.CountTracks(0)-1 do
   local tr=R.GetTrack(0,i);local key=R.GetTrackGUID(tr);local delta=R.GetMediaTrackInfo_Value(tr,'I_FOLDERDEPTH')
   rows[#rows+1]={track=tr,key=key,index=i+1,name=name(tr,i+1),depth=depth,folder=delta>0,delta=delta,
    items=R.CountTrackMediaItems(tr),fx=R.TrackFX_GetCount(tr),sets=memberships[key]or {},input=R.GetMediaTrackInfo_Value(tr,'I_RECINPUT'),
    selected=R.IsTrackSelected(tr)}
   depth=math.max(0,depth+delta)
  end
  return rows
 end
 local function find(key)
  for _,row in ipairs(T.list())do if row.key==key then return row end end
  error('That track changed. Select it again.',0)
 end
 function T.rename(key,value,project)
  M.stopped();assert(not project or project==R.EnumProjects(-1,''),'The project changed. Select the track again.')
  assert(type(value)=='string','Enter a track name.')
  value=value:match('^%s*(.-)%s*$')
  assert(value~=''and not value:find('[\r\n]'),'Enter a nonempty track name on one line.')
  local row=find(key)
  M.edit('rename track',function()assert(R.GetSetMediaTrackInfo_String(row.track,'P_NAME',value,true),'REAPER could not rename the track.')end)
 end
 function T.plan_delete(key)
  M.stopped()
  local all=T.list();local target=find(key);local rows,remove={},{}
  local items,fx=0,0
  for i=target.index,#all do
   local row=all[i]
   if i>target.index and (not target.folder or row.depth<=target.depth)then break end
   rows[#rows+1]=row;remove[row.key]=true;items=items+row.items;fx=fx+row.fx
  end
  return {key=key,project=R.EnumProjects(-1,''),revision=R.GetProjectStateChangeCount(0),all=all,rows=rows,remove=remove,items=items,fx=fx}
 end
 function T.delete(plan)
  M.stopped()
  assert(plan.project==R.EnumProjects(-1,''),'The project changed. Select the track again.')
  assert(plan.revision==R.GetProjectStateChangeCount(0),'The project changed while confirming deletion. Review the tracks again.')
  for _,row in ipairs(plan.rows)do assert(R.ValidatePtr2(0,row.track,'MediaTrack*')and R.GetTrackGUID(row.track)==row.key,'A track changed. Review the deletion again.')end
  local remaining={};for _,row in ipairs(plan.all)do if not plan.remove[row.key]then remaining[#remaining+1]=row end end
  M.edit('delete '..#plan.rows..(#plan.rows==1 and ' track'or ' tracks'),function()
   for i=#plan.rows,1,-1 do R.DeleteTrack(plan.rows[i].track)end
   -- Deleting a folder-closing child must not pull later tracks into its folder.
   for i,row in ipairs(remaining)do
    local next_depth=remaining[i+1]and remaining[i+1].depth or 0
    R.SetMediaTrackInfo_Value(row.track,'I_FOLDERDEPTH',next_depth-row.depth)
   end
  end)
  return #plan.rows
 end
 return T
end
