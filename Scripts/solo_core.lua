-- Solo Studio: project-local recording sets, fixed-lane review and native comping.
local R = reaper
local M = {ns = 'SoloStudio_v1'}
local module_dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local section_module,preview_module,recorded_tempo_module,comp_edges_module
function M.comp_edges()
  if not comp_edges_module then comp_edges_module=dofile(module_dir..'/solo_comp_edges.lua')(M)end
  return comp_edges_module
end
function M.recorded_tempo()
  if not recorded_tempo_module then recorded_tempo_module=dofile(module_dir..'/solo_recorded_tempo.lua')(M)end
  return recorded_tempo_module
end
function M.finish_recorded_tempo()
  local _,job=R.GetProjExtState(0,M.ns,'recorded_tempo.job')
  if job~=''then M.recorded_tempo().finish(R.EnumProjects(-1,''))end
end
function M.preview()
  if not preview_module then preview_module=dofile(module_dir..'/solo_comp_preview.lua')(M)end
  return preview_module
end
function M.cancel_preview(project)
  local _,journal=R.GetProjExtState(project or 0,M.ns,'comp.preview')
  if journal~='' then M.preview().cancel(project)end
end
function M.sections()
  if not section_module then section_module=dofile(module_dir..'/solo_sections.lua')(M) end
  return section_module
end
local function raw_get(key)local _,v=R.GetProjExtState(0,M.ns,key);return v end
local function resolve_tracks(id)
  local result={};local guids=raw_get('set.'..id..'.tracks')
  for guid in guids:gmatch('[^\n]+')do
    for i=0,R.CountTracks(0)-1 do local tr=R.GetTrack(0,i);if R.GetTrackGUID(tr)==guid then result[#result+1]=tr;break end end
  end
  return result
end
local function get(key)
  if key=='active'then
    local id=raw_get(key)
    if id~=''and #resolve_tracks(id)==0 then
      for candidate in raw_get('sets'):gmatch('[^\n]+')do if #resolve_tracks(candidate)>0 then return candidate end end
      return ''
    end
    return id
  end
  local id=key:match('^set%.(.+)%.name$')
  if id then
    -- Single-track instruments follow native names, including native Undo/Redo.
    local guids=raw_get('set.'..id..'.tracks')
    if guids~=''and not guids:find('\n',1,true)then
      local tr=resolve_tracks(id)[1]
      if tr then local _,name=R.GetSetMediaTrackInfo_String(tr,'P_NAME','',false);if name~=''then return name end end
    end
  end
  return raw_get(key)
end
local function put(key,value) R.SetProjExtState(0,M.ns,key,tostring(value)); R.MarkProjectDirty(0) end
M.get, M.put = get, put
local function split(s) local t={} for v in (s or ''):gmatch('[^\n]+') do t[#t+1]=v end return t end
local function str(tr,key) local _,v=R.GetSetMediaTrackInfo_String(tr,key,'',false); return v end
local function itemstr(it,key) local _,v=R.GetSetMediaItemInfo_String(it,key,'',false); return v end
M.track_name=function(tr) return str(tr,'P_NAME') end
M.message=function(s) R.ShowMessageBox(s,'Solo Studio',0) end
local function annotation(key,value)
  local tr=M.require_tracks()[1]
  if value~=nil then R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudio.'..key,tostring(value),true);R.MarkProjectDirty(0) end
  return str(tr,'P_EXT:SoloStudio.'..key)
end
function M.stopped()
  if R.GetPlayState() & 4 ~= 0 then error('Finish recording before changing takes or the recording set.',0) end
end
function M.edit(name,fn)
  M.stopped(); M.cancel_preview(); M.finish_recorded_tempo(); R.Undo_BeginBlock2(0); R.PreventUIRefresh(1)
  local ok,result=xpcall(fn,debug.traceback)
  R.PreventUIRefresh(-1); R.UpdateTimeline(); R.TrackList_AdjustWindows(false)
  R.Undo_EndBlock2(0,'Solo Studio: '..name,-1)
  if not ok then error(result,0) end
  return result
end
function M.history(redo)
  M.stopped()
  local project=R.EnumProjects(-1,'')
  local label=(redo and R.Undo_CanRedo2 or R.Undo_CanUndo2)(project)
  if not label or label==''then return end
  -- Do not wrap Undo in M.edit: that would create a new entry and discard Redo.
  local result=(redo and R.Undo_DoRedo2 or R.Undo_DoUndo2)(project)
  assert(result~=0,'REAPER could not '..(redo and 'redo' or 'undo')..' this edit.')
  return label
end
function M.selected()
  local t={}; for i=0,R.CountSelectedTracks(0)-1 do t[#t+1]=R.GetSelectedTrack(0,i) end; return t
end
function M.select_tracks(tracks)
  for i=0,R.CountTracks(0)-1 do R.SetTrackSelected(R.GetTrack(0,i),false) end
  for _,tr in ipairs(tracks) do R.SetTrackSelected(tr,true) end
end
function M.sets()
  local t={};for _,id in ipairs(split(get('sets')))do
    if #resolve_tracks(id)>0 then t[#t+1]={id=id,name=get('set.'..id..'.name')}end
  end;return t
end
function M.tracks()
  -- Retain registered GUIDs: native track Undo restores membership automatically.
  local t=resolve_tracks(get('active'))
  return t,#t==0 and 'Select tracks in REAPER, then choose Use selected tracks.' or nil
end
function M.require_tracks()
  local t,err=M.tracks(); if err then error(err,0) end; return t
end
function M.prepare(tracks)
  for _,tr in ipairs(tracks) do
    if R.GetMediaTrackInfo_Value(tr,'I_FREEMODE')==1 then error('Turn off free item positioning before preparing '..M.track_name(tr)..'.',0) end
    for i=0,R.CountTrackMediaItems(tr)-1 do
      if R.GetMediaItemNumTakes(R.GetTrackMediaItem(tr,i))>1 then error('This track uses stacked takes. Convert its takes to fixed lanes in REAPER first.',0) end
    end
  end
  for _,tr in ipairs(tracks) do
    R.SetMediaTrackInfo_Value(tr,'I_FREEMODE',2)
    local flags=math.floor(R.GetMediaTrackInfo_Value(tr,'C_LANESETTINGS'))
    R.SetMediaTrackInfo_Value(tr,'C_LANESETTINGS',(flags | 2 | 4 | 8 | 16) & ~32)
    R.SetMediaTrackInfo_Value(tr,'C_LANESCOLLAPSED',0)
  end
  R.UpdateTimeline()
end
function M.capture(name)
  local tracks=M.selected(); if #tracks==0 then error('Select the instrument track, or all microphone tracks for one performance.',0) end
  for _,tr in ipairs(tracks) do if R.GetMediaTrackInfo_Value(tr,'I_FOLDERDEPTH')==1 then error('Select the microphone tracks inside the folder, leaving the folder itself unselected.',0) end end
  local selected={};local mask=0;local high=0
  for _,tr in ipairs(tracks) do
    selected[tr]=true
    for _,role in ipairs({'MEDIA_EDIT_LEAD','MEDIA_EDIT_FOLLOW'}) do
      mask=mask | R.GetSetTrackGroupMembership(tr,role,0,0)
      high=high | R.GetSetTrackGroupMembershipHigh(tr,role,0,0)
    end
  end
  for i=0,R.CountTracks(0)-1 do
    local tr=R.GetTrack(0,i)
    if not selected[tr] then for _,role in ipairs({'MEDIA_EDIT_LEAD','MEDIA_EDIT_FOLLOW'}) do
      if R.GetSetTrackGroupMembership(tr,role,0,0)&mask~=0 or R.GetSetTrackGroupMembershipHigh(tr,role,0,0)&high~=0 then
        error('These tracks share an edit group with '..M.track_name(tr)..'. Include every microphone in that group, or unlink it first.',0)
      end
    end end
  end
  local id
  local guids={}; for _,tr in ipairs(tracks) do guids[#guids+1]=R.GetTrackGUID(tr) end
  local joined=table.concat(guids,'\n')
  for _,set in ipairs(M.sets()) do if get('set.'..set.id..'.tracks')==joined then id=set.id end end
  M.edit('prepare '..name,function()
    M.prepare(tracks)
    if not id then
      id=R.genGuid(); local ids=split(get('sets')); ids[#ids+1]=id; put('sets',table.concat(ids,'\n'))
      if #tracks>1 then
        local already=false
        for _,tr in ipairs(tracks) do
          if R.GetSetTrackGroupMembership(tr,'MEDIA_EDIT_LEAD',0,0)~=0 or R.GetSetTrackGroupMembership(tr,'MEDIA_EDIT_FOLLOW',0,0)~=0 then already=true end
        end
        if not already then R.Main_OnCommand(42578,0) end
      end
    end
    put('set.'..id..'.name',name); put('set.'..id..'.tracks',joined); put('active',id)
    if R.GetToggleCommandStateEx(0,1156)==0 then R.Main_OnCommand(1156,0) end
  end)
  return id
end
function M.choose_set(id)
  M.stopped(); M.cancel_preview(); put('active',id); M.select_tracks(M.require_tracks()); R.TrackList_AdjustWindows(false)
end
function M.arm()
  local tracks=M.require_tracks(); M.stopped()
  local n=R.GetNumAudioInputs()
  for _,tr in ipairs(tracks) do
    local input=R.GetMediaTrackInfo_Value(tr,'I_RECINPUT')
    if input<0 or input>=4096 or (input & 1023)>=n then error('Choose a connected audio input for '..M.track_name(tr)..' using Inputs first.',0) end
  end
  M.edit('arm recording set',function()
    R.ClearAllRecArmed()
    for _,tr in ipairs(tracks) do R.SetMediaTrackInfo_Value(tr,'I_RECMODE',0); R.SetMediaTrackInfo_Value(tr,'I_RECARM',1) end
  end)
end
function M.record()
  if R.GetPlayState() & 4 ~= 0 then M.stop(); return end
  local _,file=R.EnumProjects(-1,'')
  if file=='' then error('Save this project in its own folder before recording (Cmd+Shift+S).',0) end
  M.arm()
  local ok,err=pcall(function()
    local endpoint,punch=M.sections().prepare_record()
    local tempo=M.recorded_tempo();local project=R.EnumProjects(-1,'')
    tempo.begin(project,M.require_tracks())
    R.Main_OnCommand(43152,0);R.Main_OnCommand(1013,0)
    local job=tempo.job(project);if R.GetPlayState()&4~=0 then tempo.observe(project,job)end
    tempo.watch();M.sections().start_watch(endpoint,punch)
  end)
  if not ok then M.stop();error(err,0)end
end
function M.stop()
  M.cancel_preview()
  if R.GetPlayState() & 4 ~= 0 then R.Main_OnCommand(40667,0) else R.OnStopButton() end
  M.sections().cancel_watch()
  M.finish_recorded_tempo()
end
function M.another()
  M.stop()
  if M.sections().mode()=='full' or M.sections().mode()=='section' then M.record();return end
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  if e<=s then error('Select a passage in the timeline, or choose a loop length first.',0) end
  R.SetEditCurPos2(0,s,false,false); M.record()
end
function M.loop_bars(bars)
  M.stopped();M.sections().manual()
  local _,measure=R.TimeMap2_timeToBeats(0,R.GetCursorPosition())
  local s=R.TimeMap_GetMeasureInfo(0,measure)
  local e=R.TimeMap_GetMeasureInfo(0,measure+bars)
  R.GetSet_LoopTimeRange2(0,true,false,s,e,false); R.GetSet_LoopTimeRange2(0,true,true,s,e,false)
  R.GetSetRepeat(1); R.SetEditCurPos2(0,s,true,false)
end
function M.lane_items(tr,lane)
  local t={}; for i=0,R.CountTrackMediaItems(tr)-1 do
    local it=R.GetTrackMediaItem(tr,i)
    if R.GetMediaItemInfo_Value(it,'I_FIXEDLANE')==lane then t[#t+1]=it end
  end
  table.sort(t,function(a,b) return R.GetMediaItemInfo_Value(a,'D_POSITION')<R.GetMediaItemInfo_Value(b,'D_POSITION') end)
  return t
end
function M.covers(items,s,e)
  local pos=s
  for _,it in ipairs(items) do
    local p=R.GetMediaItemInfo_Value(it,'D_POSITION'); local q=p+R.GetMediaItemInfo_Value(it,'D_LENGTH')
    if p>pos+0.00001 then break end
    if q>pos then pos=q end
    if pos>=e-0.00001 then return true end
  end
  return false
end
function M.comp_lane(tr)
  local ids={};for _,id in ipairs(split(str(tr,'P_EXT:SoloStudioComp')))do ids[id]=true end
  for i=0,R.CountTrackMediaItems(tr)-1 do local it=R.GetTrackMediaItem(tr,i)
    if ids[itemstr(it,'GUID')]then return R.GetMediaItemInfo_Value(it,'I_FIXEDLANE')end
  end
end
function M.row_for_key(key)for _,row in ipairs(M.lanes())do if row.key==key then return row end end end
function M.lanes()
  local tracks=M.tracks(); if #tracks==0 then return {} end
  local rows={};local comp=M.comp_lane(tracks[1]);local count=math.floor(R.GetMediaTrackInfo_Value(tracks[1],'I_NUMFIXEDLANES'))
  for n=0,count-1 do
    local items=M.lane_items(tracks[1],n)
    if #items>0 then
      local name=str(tracks[1],'P_LANENAME:'..n); if name=='' then name='Take '..(n+1) end
      local key=itemstr(items[1],'GUID')
      rows[#rows+1]={lane=n,name=name,key=key,items=items,is_comp=n==comp,is_preview=itemstr(items[1],'P_EXT:SoloStudioPreview')~='',playing=R.GetMediaTrackInfo_Value(tracks[1],'C_LANEPLAYS:'..n)>0,
        favorite=annotation('favorite.'..key)=='1',note=annotation('note.'..key),tempo=M.recorded_tempo().describe(items)}
    end
  end
  return rows
end
function M.row_for_lane(lane) for _,row in ipairs(M.lanes()) do if row.lane==lane then return row end end end
-- Remove project items, never their source files. Keep empty native lanes so
-- source/comp lane indices remain aligned across microphones.
function M.delete_takes(takes,listen_key)
  M.stopped();M.cancel_preview()
  assert(type(takes)=='table' and #takes>0,'Select at least one take to delete.')
  local tracks=M.require_tracks();local live={};local lanes={};local total=0
  for _,row in ipairs(M.lanes())do live[row.lane]=row end
  for _,take in ipairs(takes)do
    local row=live[take.lane]
    assert(row and row.key==take.key,'A selected take changed. Select it again before deleting.')
    if not lanes[take.lane]then lanes[take.lane]=true;total=total+1 end
  end
  local listen
  if listen_key then
    listen=assert(M.row_for_key(listen_key),'The next take changed. Select it again before deleting.')
    assert(not lanes[listen.lane]and not listen.is_comp and not listen.is_preview,'The next take must be a surviving source lane.')
    M.validate_lane(tracks,listen.lane)
  end
  local count=R.GetMediaTrackInfo_Value(tracks[1],'I_NUMFIXEDLANES')
  local saved={}
  for _,tr in ipairs(tracks) do
    assert(R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')==count,'The microphone tracks have different lane counts. Align their take lanes before deleting.')
    local ok,chunk=R.GetTrackStateChunk(tr,'',false)
    assert(ok,'Could not prepare an undoable deletion for '..M.track_name(tr)..'.')
    local items={}
    for lane in pairs(lanes)do for _,it in ipairs(M.lane_items(tr,lane))do items[#items+1]=it end end
    saved[#saved+1]={track=tr,chunk=chunk,items=items}
  end
  M.edit('delete '..total..(total==1 and ' take' or ' takes')..' across recording set',function()
    local ok,err=xpcall(function()
      for _,snapshot in ipairs(saved) do
        local tr=snapshot.track;local removed={}
        for _,it in ipairs(snapshot.items) do
          removed[itemstr(it,'GUID')]=true
          assert(R.DeleteTrackMediaItem(tr,it),'REAPER could not remove every item in the take.')
        end
        for lane in pairs(lanes)do assert(#M.lane_items(tr,lane)==0,'REAPER left items in a deleted take.')end
        local comp={}
        for _,id in ipairs(split(str(tr,'P_EXT:SoloStudioComp'))) do if not removed[id] then comp[#comp+1]=id end end
        R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudioComp',table.concat(comp,'\n'),true)
        if listen then
          R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..listen.lane,1)
          assert(R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..listen.lane)==1,'REAPER could not switch every microphone to the next take.')
        end
      end
    end,debug.traceback)
    if not ok then
      local restored=true
      for _,snapshot in ipairs(saved) do if not R.SetTrackStateChunk(snapshot.track,snapshot.chunk,false) then restored=false end end
      error(restored and (err..'\nThe original tracks were restored.') or 'Deletion failed and restoration was incomplete. Use REAPER Undo immediately.',0)
    end
  end)
end
function M.delete_take(lane,key)return M.delete_takes({{lane=lane,key=key}})end
function M.validate_lane(tracks,lane,range)
  local counts={}
  for _,tr in ipairs(tracks) do
    local count=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES'); counts[count]=true
    if lane>=count or #M.lane_items(tr,lane)==0 then error('This take is missing on '..M.track_name(tr)..'. Match the recording passes before switching.',0) end
    if range and not M.covers(M.lane_items(tr,lane),range[1],range[2]) then error('This take does not cover the whole selected passage on '..M.track_name(tr)..'.',0) end
  end
  local kinds=0; for _ in pairs(counts) do kinds=kinds+1 end
  if kinds>1 then error('The microphone tracks have different lane counts. Align their take lanes before comparing.',0) end
end
function M.audition(lane,whole_lane)
  local tracks=M.require_tracks(); M.stopped();M.cancel_preview()
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  M.validate_lane(tracks,lane,not whole_lane and e>s and {s,e} or nil)
  local old={}
  for i,tr in ipairs(tracks) do old[i]={}; for n=0,R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')-1 do old[i][n]=R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..n) end end
  M.edit('audition take',function()
    local ok=true
    for _,tr in ipairs(tracks) do
      R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..lane,1)
      if R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..lane)~=1 then ok=false end
    end
    if not ok then
      for i,tr in ipairs(tracks) do
        R.SetMediaTrackInfo_Value(tr,'C_ALLLANESPLAY',0)
        for n,v in pairs(old[i]) do if v>0 then R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..n,2) end end
      end
      error('REAPER could not switch every microphone. Previous lane playback was restored.',0)
    end
    put('selected.'..get('active'),lane)
  end)
end
function M.step(direction)
  local rows=M.sections().filter_takes(M.lanes()); if #rows==0 then error('Record or import some takes for this section first.',0) end
  local idx=1; for i,row in ipairs(rows) do if row.playing then idx=i end end
  idx=((idx-1+direction)%#rows)+1; M.audition(rows[idx].lane)
end
function M.favorite(lane)
  local row=M.row_for_lane(lane); if not row then error('Choose a take first.',0) end
  M.edit('rate take',function() annotation('favorite.'..row.key,row.favorite and '0' or '1') end)
end
function M.note(lane,text,section)
  local row=M.row_for_lane(lane); if not row then error('Choose a take first.',0) end
  local key='note.'..row.key
  if section then key=key..string.format('.%.6f.%.6f',section[1],section[2]) end
  M.edit('annotate take',function() annotation(key,text) end)
end
function M.section_note(lane,s,e)
  local row=M.row_for_lane(lane); return row and annotation('note.'..row.key..string.format('.%.6f.%.6f',s,e)) or ''
end
function M.inputs(numbers)
  local tracks=M.require_tracks(); if #numbers~=#tracks then error('Provide one mono input number for each track.',0) end
  for _,v in ipairs(numbers) do if v%1~=0 or v<1 or v>R.GetNumAudioInputs() then error('Input numbers must match the connected interface.',0) end end
  M.edit('assign audio inputs',function() for i,tr in ipairs(tracks) do R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',numbers[i]-1) end end)
end
function M.add_instrument(kind,names)
  local color={Vocals={130,175,216},Guitar={221,184,104},Bass={160,184,131},Drums={190,151,196}}
  local c=color[kind] or color.Vocals; local tracks={}
  M.edit('add '..kind,function()
    for _,name in ipairs(names or {kind}) do
      local idx=R.CountTracks(0); R.InsertTrackAtIndex(idx,true); local tr=R.GetTrack(0,idx); tracks[#tracks+1]=tr
      R.GetSetMediaTrackInfo_String(tr,'P_NAME',name,true)
      R.SetTrackColor(tr,R.ColorToNative(c[1],c[2],c[3])|0x1000000)
      R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',-1); R.SetMediaTrackInfo_Value(tr,'I_RECMON',0)
      R.SetMediaTrackInfo_Value(tr,'C_BEATATTACHMODE',0)
    end
    M.select_tracks(tracks)
  end)
  M.capture(kind); return tracks
end
function M.listen_comp()
  M.stopped();M.cancel_preview()
  local tracks=M.require_tracks();local lane=M.comp_lane(tracks[1])
  assert(lane,'Build a comp with Use in comp first.')
  for _,tr in ipairs(tracks)do assert(M.comp_lane(tr)==lane,'The comp lanes do not match across the microphones.')end
  M.audition(lane,true)
end
function M.use_in_comp(key,s,e)
  M.stopped();M.cancel_preview()
  local row=assert(M.row_for_key(key),'This take changed. Select it again.')
  assert(not row.is_comp and not row.is_preview,'Select a source take.')
  M.comp(row.lane,{s,e})
end
function M.comp(lane,range)
  M.stopped();M.cancel_preview()
  local tracks=M.require_tracks();local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  if range then s,e=range[1],range[2]end
  assert(type(s)=='number' and type(e)=='number' and s==s and e==e and s>=0 and e<math.huge and e-s>0.00001,'Select a non-empty passage to use in the comp.')
  local source_row=assert(M.row_for_lane(lane),'Select a source take.')
  M.validate_lane(tracks,lane,{s,e})
  local saved_tracks=M.selected(); local razor={}; local originals={};local chunks={};local comp_lanes={};local existing=0
  for i=0,R.CountTracks(0)-1 do local tr=R.GetTrack(0,i); razor[tr]=str(tr,'P_RAZOREDITS_EXT') end
  for i,tr in ipairs(tracks) do
    originals[i]=M.lane_items(tr,lane)[1]
    local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok,'Could not prepare the comp edit.');chunks[tr]=chunk
    local ids={};for _,id in ipairs(split(str(tr,'P_EXT:SoloStudioComp'))) do ids[id]=true end
    for j=0,R.CountTrackMediaItems(tr)-1 do local it=R.GetTrackMediaItem(tr,j)
      if ids[itemstr(it,'GUID')] then comp_lanes[i]=R.GetMediaItemInfo_Value(it,'I_FIXEDLANE');break end
    end
    if comp_lanes[i] then existing=existing+1 end
    if comp_lanes[i]==lane then error('Choose a source take before keeping a passage.',0) end
  end
  if existing>0 and existing<#tracks then error('The saved comp is missing on one microphone. Restore it with Undo before continuing.',0) end
  M.edit('keep selected passage',function()
    local ok,err=xpcall(function()
      M.select_tracks(tracks)
      for _,tr in ipairs(tracks)do for _,it in ipairs(M.lane_items(tr,lane))do
        R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioSource',source_row.key,true)
        R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioSourceName',source_row.name,true)
      end end
      if existing==0 then R.Main_OnCommand(42797,0) end
      for tr in pairs(razor) do R.GetSetMediaTrackInfo_String(tr,'P_RAZOREDITS_EXT','',true) end
      local before={}
      for i,tr in ipairs(tracks) do
        before[i]={};for j=0,R.CountTrackMediaItems(tr)-1 do before[i][itemstr(R.GetTrackMediaItem(tr,j),'GUID')]=true end
        local n=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')
        local source=R.GetMediaItemInfo_Value(originals[i],'I_FIXEDLANE')
        local area=string.format('%.14f %.14f "" %.14f %.14f',s,e,source/n,(source+1)/n)
        R.GetSetMediaTrackInfo_String(tr,'P_RAZOREDITS_EXT',area,true)
      end
      R.Main_OnCommand(42475,0)
      for i,tr in ipairs(tracks) do
        if not comp_lanes[i] then
          for j=0,R.CountTrackMediaItems(tr)-1 do local it=R.GetTrackMediaItem(tr,j)
            if not before[i][itemstr(it,'GUID')] then comp_lanes[i]=R.GetMediaItemInfo_Value(it,'I_FIXEDLANE');break end
          end
        end
        if not comp_lanes[i] or not M.covers(M.lane_items(tr,comp_lanes[i]),s,e) then error('REAPER did not create the requested comp on every microphone. The original tracks have been restored.',0) end
        -- Native comping may reuse a destination item's old extension fields.
        -- Match actual source audio/timing before copying recording provenance.
        local live_source=R.GetMediaItemInfo_Value(originals[i],'I_FIXEDLANE')
        for _,it in ipairs(M.lane_items(tr,comp_lanes[i]))do
          local p=R.GetMediaItemInfo_Value(it,'D_POSITION');local q=p+R.GetMediaItemInfo_Value(it,'D_LENGTH')
          local take=R.GetActiveTake(it)
          if take and q>s and p<e then
            local file=R.GetMediaSourceFileName(R.GetMediaItemTake_Source(take),'')
            local rate=R.GetMediaItemTakeInfo_Value(take,'D_PLAYRATE');local offset=R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')
            for _,source in ipairs(M.lane_items(tr,live_source))do
              local st=R.GetActiveTake(source);local a=R.GetMediaItemInfo_Value(source,'D_POSITION');local b=a+R.GetMediaItemInfo_Value(source,'D_LENGTH')
              if st and q>a and p<b and file~=''and file==R.GetMediaSourceFileName(R.GetMediaItemTake_Source(st),'')
                and math.abs(rate-R.GetMediaItemTakeInfo_Value(st,'D_PLAYRATE'))<0.00001
                and math.abs(offset-(R.GetMediaItemTakeInfo_Value(st,'D_STARTOFFS')+(p-a)*rate))<0.00001 then
                for _,field in ipairs({'P_EXT:SoloStudioSource','P_EXT:SoloStudioSourceName','P_EXT:SoloStudioRecordedTempo','P_EXT:SoloStudioRecordingBounds'})do
                  R.GetSetMediaItemInfo_String(it,field,itemstr(source,field),true)
                end
                break
              end
            end
          end
        end
        local ids={};for _,it in ipairs(M.lane_items(tr,comp_lanes[i])) do ids[#ids+1]=itemstr(it,'GUID') end
        R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudioComp',table.concat(ids,'\n'),true)
        R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..comp_lanes[i],'Comp',true)
        R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..comp_lanes[i],1)
        assert(R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..comp_lanes[i])==1,'Could not activate the comp on every microphone.')
      end
    end,debug.traceback)
    if not ok then for tr,chunk in pairs(chunks) do R.SetTrackStateChunk(tr,chunk,false) end end
    for tr,value in pairs(razor) do R.GetSetMediaTrackInfo_String(tr,'P_RAZOREDITS_EXT',value,true) end
    M.select_tracks(saved_tracks)
    if not ok then error(err,0) end
  end)
end
return M
