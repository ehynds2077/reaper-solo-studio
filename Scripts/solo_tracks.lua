-- Project track management. Native GUIDs keep recording sets attached through Undo.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
return function(M,options)
 local T={}
 local envelope_cache,envelope_project,envelope_revision={},nil,nil
 local function available()
  M.stopped();assert(not (options and options.busy and options.busy()),'Finish the current AI mix operation before changing tracks.')
 end
 local function envelope(tr,key)
  local id=R.GetTrackGUID(tr)..key
  if envelope_cache[id]~=nil then return envelope_cache[id]end
  local env=R.GetTrackEnvelopeByChunkName(tr,key)
  if not env then envelope_cache[id]=false;return false end
  local ok,chunk=R.GetEnvelopeStateChunk(env,'',false)
  local active=not ok or chunk:match('\n%s*ACT%s+1')~=nil
  envelope_cache[id]=active;return active
 end
 local function str(tr,key)local _,value=R.GetSetMediaTrackInfo_String(tr,key,'',false);return value end
 local function clean_name(value)
  assert(type(value)=='string','Enter a name.');value=value:match('^%s*(.-)%s*$')
  assert(value~=''and not value:find('%c'),'Enter a nonempty name on one line.');return value
 end
 local function edit_values(label,changes)
  -- A failed write restores the entire operation, including mute/name metadata.
  for _,c in ipairs(changes)do c.before=type(c.value)=='string'and str(c.track,c.key)or R.GetMediaTrackInfo_Value(c.track,c.key)end
  local function write(c,value)
   if type(value)=='string'then
    -- Removing an empty P_EXT field can report false even though it succeeded.
    R.GetSetMediaTrackInfo_String(c.track,c.key,value,true);return str(c.track,c.key)==value
   end
   R.SetMediaTrackInfo_Value(c.track,c.key,value)
   return math.abs(R.GetMediaTrackInfo_Value(c.track,c.key)-value)<1e-9
  end
  M.edit(label,function()
   local ok,err=pcall(function()for _,c in ipairs(changes)do assert(write(c,c.value),'REAPER could not update the track.')end end)
   if not ok then for _,c in ipairs(changes)do write(c,c.before)end;error(err,0)end
  end)
 end
 function T.db(gain)return gain>0 and 20*math.log(gain,10)or -math.huge end
 local function mix_state(row)
  local peak,muted=0,0
  for _,member in ipairs(row.members)do
   peak=math.max(peak,member.volume);if member.muted then muted=muted+1 end
   row.volume_automated=row.volume_automated or member.volume_automated
   row.mute_automated=row.mute_automated or member.mute_automated
  end
  row.volume=peak;row.db=T.db(peak);row.muted=muted==#row.members;row.mixed_mute=muted>0 and muted<#row.members
  return row
 end
 local function name(tr,index)local value=M.track_name(tr);return value~=''and value or 'Track '..index end
 function T.list()
  local project,revision=R.EnumProjects(-1,''),R.GetProjectStateChangeCount(0)
  if project~=envelope_project or revision~=envelope_revision then
   envelope_cache={};envelope_project=project;envelope_revision=revision
  end
  local memberships={}
  for _,set in ipairs(M.sets())do for guid in M.get('set.'..set.id..'.tracks'):gmatch('[^\n]+')do
   memberships[guid]=memberships[guid]or {};table.insert(memberships[guid],set)
  end end
  local rows={};local depth=0
  for i=0,R.CountTracks(0)-1 do
   local tr=R.GetTrack(0,i);local key=R.GetTrackGUID(tr);local delta=R.GetMediaTrackInfo_Value(tr,'I_FOLDERDEPTH')
   rows[#rows+1]={track=tr,key=key,index=i+1,name=name(tr,i+1),depth=depth,folder=delta>0,delta=delta,
    items=R.CountTrackMediaItems(tr),fx=R.TrackFX_GetCount(tr),sets=memberships[key]or {},input=R.GetMediaTrackInfo_Value(tr,'I_RECINPUT'),
    selected=R.IsTrackSelected(tr),volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),muted=R.GetMediaTrackInfo_Value(tr,'B_MUTE')~=0,
    volume_automated=envelope(tr,'<VOLENV2'),mute_automated=envelope(tr,'<MUTEENV')}
   depth=math.max(0,depth+delta)
  end
  return rows
 end
 function T.groups()
  local all,by_key,used,groups=T.list(),{},{},{}
  for _,row in ipairs(all)do by_key[row.key]=row end
  for _,set in ipairs(M.sets())do
   local members,seen={},{}
   for guid in M.get('set.'..set.id..'.tracks'):gmatch('[^\n]+')do
    if by_key[guid]and not seen[guid]then members[#members+1]=by_key[guid];seen[guid]=true;used[guid]=true end
   end
   if #members>0 then groups[#groups+1]=mix_state({key='set:'..set.id,id=set.id,name=set.name,members=members,active=M.get('active')==set.id})end
  end
  local others={};for _,row in ipairs(all)do if not used[row.key]then others[#others+1]=row end end
  if #others>0 then groups[#groups+1]={key='other',name='Other tracks',members=others,other=true}end
  return groups
 end
 local function find(key)
  for _,row in ipairs(T.list())do if row.key==key then return row end end
  error('That track changed. Select it again.',0)
 end
 function T.rename(key,value,project)
  available();assert(not project or project==R.EnumProjects(-1,''),'The project changed. Select the track again.')
  value=clean_name(value)
  local row=find(key)
  M.edit('rename track',function()assert(R.GetSetMediaTrackInfo_String(row.track,'P_NAME',value,true),'REAPER could not rename the track.')end)
 end
 local function resolve(row,project)
  available();assert(not project or project==R.EnumProjects(-1,''),'The project changed. Select the group again.')
  local current
  if row.id then for _,group in ipairs(T.groups())do if group.id==row.id then current=group;break end end
  else local track=find(row.key);current=mix_state({key=track.key,name=track.name,members={track}})end
  assert(current and #current.members==#row.members,'The tracks changed. Select the group again.')
  for i,member in ipairs(current.members)do assert(member.key==row.members[i].key,'The group membership changed. Try again.')end
  return current
 end
 function T.track(row)return mix_state({key=row.key,name=row.name,members={row}})end
 function T.rename_group(row,value,project)
  local current=resolve(row,project);value=clean_name(value)
  local raw=M.get('set.'..row.id..'.tracks')
  if not raw:find('\n',1,true)then return T.rename(current.members[1].key,value,project)end
  local changes={};for _,member in ipairs(current.members)do changes[#changes+1]={track=member.track,key='P_EXT:SoloStudio.set_name.'..row.id,value=value}end
  edit_values('rename '..current.name..' group',changes)
 end
 function T.set_volume(row,db,project)
  assert(type(db)=='number'and db==db and db>=-60 and db<=24,'Enter a volume between -60 and +24 dB.')
  local current=resolve(row,project)
  assert(not current.volume_automated,'This volume is automated. Adjust its envelope in REAPER.')
  assert(current.volume>0 or #current.members==1,'All group faders are silent. Expand the group and set individual levels first.')
  local changes={};local target=10^(db/20)
  for i,member in ipairs(current.members)do
   assert(math.abs(member.volume-row.members[i].volume)<1e-9,'A track volume changed during the adjustment. Try again.')
   local gain=current.volume>0 and member.volume/current.volume*target or target
   changes[#changes+1]={track=member.track,key='D_VOL',value=gain}
  end
  edit_values('set '..current.name..' volume',changes)
 end
 local mute_field='P_EXT:SoloStudio.group_mutes'
 function T.toggle_mute(row,project)
  local current=resolve(row,project)
  assert(not current.mute_automated,'This mute is automated. Adjust its envelope in REAPER.')
  local changes={}
  for _,member in ipairs(current.members)do
   local value=current.muted and 0 or 1;local saved={}
   local raw=str(member.track,mute_field)
   if raw~=''then local ok,decoded=pcall(J.decode,raw);assert(ok and type(decoded)=='table'and type(decoded.owners)=='table','Could not read the saved group mute state.');saved=decoded end
   if row.id then
    saved.owners=saved.owners or {};saved.base=saved.base or (member.muted and 1 or 0)
    if current.muted then
     local owned=saved.owners[row.id];saved.owners[row.id]=nil
     if next(saved.owners)then value=1 elseif owned then value=saved.base end
    else saved.owners[row.id]=true;value=1 end
   else saved={}end -- An explicit individual toggle supersedes group mute ownership.
   changes[#changes+1]={track=member.track,key=mute_field,value=saved.owners and next(saved.owners)and J.encode(saved)or ''}
   changes[#changes+1]={track=member.track,key='B_MUTE',value=value}
  end
  edit_values((current.muted and 'unmute 'or 'mute ')..current.name,changes)
 end
 local function plan_remove(keys,label)
  available()
  local all=T.list();local rows,remove={},{}
  for _,key in ipairs(keys)do
   local target=find(key)
   for i=target.index,#all do
    local row=all[i]
    if i>target.index and (not target.folder or row.depth<=target.depth)then break end
    remove[row.key]=true
   end
  end
  local items,fx=0,0
  for _,row in ipairs(all)do if remove[row.key]then rows[#rows+1]=row;items=items+row.items;fx=fx+row.fx end end
  return {key=keys[1],name=label,project=R.EnumProjects(-1,''),revision=R.GetProjectStateChangeCount(0),all=all,rows=rows,remove=remove,items=items,fx=fx}
 end
 function T.plan_delete(key)return plan_remove({key},find(key).name)end
 function T.plan_delete_group(row,project)
  local current=resolve(row,project);local keys={}
  for _,member in ipairs(current.members)do keys[#keys+1]=member.key end
  return plan_remove(keys,current.name)
 end
 function T.delete(plan)
  available()
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
