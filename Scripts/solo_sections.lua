-- Song structure is stored as ordinary REAPER regions. Audio is never split.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
return function(M)
 local S={}
 local leadin,handles
 local function lead()if not leadin then leadin=dofile(dir..'/solo_leadin.lua')end;return leadin end
 local function capture()if not handles then handles=dofile(dir..'/solo_recording_handles.lua')end;return handles end
 local function get(k)return M.get('song.'..k)end
 local function put(k,v)M.put('song.'..k,v)end
 local function valid_range(s,e)
  if type(s)~='number' or type(e)~='number' or s~=s or e~=e or s<0 or e-s<0.001 or e==math.huge then error('Choose a non-empty section within the song.',0) end
 end
 function S.list()
  local rows={};local i=0
  while true do
   local ok,region,s,e,name,id,color=R.EnumProjectMarkers3(0,i)
   if ok==0 then break end
   if region then
    local found,guid=R.GetSetProjectInfo_String(0,'MARKER_GUID:'..i,'',false)
    assert(found and guid~='','This REAPER version cannot identify song regions.')
    rows[#rows+1]={id=id,key=guid,s=s,e=e,name=name~='' and name or 'Section '..id,color=color}
   end
   i=i+1
  end
  table.sort(rows,function(a,b)return a.s==b.s and a.id<b.id or a.s<b.s end)
  return rows
 end
 function S.find(key)
  for _,row in ipairs(S.list())do if row.key==key then return row end end
 end
 function S.active()return S.find(get('section'))end
 function S.mode()return get('mode')end
 function S.looping()return get('loop')=='1'end
 function S.snapping()return get('snap')~='0'end
 function S.set_snap(value)put('snap',value and '1' or '0')end
 function S.snap(pos)
  if not S.snapping() then return pos end
  local _,measure=R.TimeMap2_timeToBeats(0,pos)
  local a=R.TimeMap_GetMeasureInfo(0,measure)
  local b=R.TimeMap_GetMeasureInfo(0,measure+1)
  return pos-a<=b-pos and a or b
 end
 function S.position()
  return R.GetPlayState()&1~=0 and R.GetPlayPosition() or R.GetCursorPosition()
 end
 local function name(value)
  value=tostring(value or ''):match('^%s*(.-)%s*$')
  if value=='' then error('Give this section a name.',0) end
  return value
 end
 local function no_overlap(s,e,except)
  for _,row in ipairs(S.list())do
   if row.key~=except and s<row.e-0.00001 and e>row.s+0.00001 then error('This overlaps '..row.name..'. Split that section or adjust its bounds.',0) end
  end
 end
 local function add(s,e,label,color)
  local id=R.AddProjectMarker2(0,true,s,e,label,-1,color or (R.ColorToNative(89,148,194)|0x1000000))
  assert(id>=0,'REAPER could not create the section.')
  for _,row in ipairs(S.list())do if row.id==id then return row end end
  error('The new section was not found.',0)
 end
 function S.create(s,e,label)
  M.stopped();valid_range(s,e);label=name(label);no_overlap(s,e)
  local row
  M.edit('add song section',function()row=add(s,e,label);put('section',row.key)end)
  return row
 end
 function S.from_selection(label)
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  return S.create(s,e,label)
 end
 function S.from_scratch()
  M.stopped()
  if #S.list()>0 then error('The song already has sections. Use Mark transition to divide them further.',0)end
  local ids={}
  for _,set in ipairs(M.sets())do
   if set.name:lower():find('scratch',1,true)then
    for guid in M.get('set.'..set.id..'.tracks'):gmatch('[^\n]+')do ids[guid]=true end
   end
  end
  local first,last=math.huge,0
  for i=0,R.CountTracks(0)-1 do
   local tr=R.GetTrack(0,i)
   if ids[R.GetTrackGUID(tr)]then
    for j=0,R.CountTrackMediaItems(tr)-1 do
     local it=R.GetTrackMediaItem(tr,j)
     local lane=R.GetMediaItemInfo_Value(it,'I_FIXEDLANE')
     if R.GetMediaTrackInfo_Value(tr,'I_FREEMODE')~=2 or R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..lane)>0 then
      local p=R.GetMediaItemInfo_Value(it,'D_POSITION');local e=p+R.GetMediaItemInfo_Value(it,'D_LENGTH')
      first=math.min(first,p);last=math.max(last,e)
     end
    end
   end
  end
  if first==math.huge then error('Choose a playing scratch take first, or create a section from a time selection.',0)end
  return S.create(math.max(0,first),last,'Song')
 end
 function S.split(pos)
  M.stopped();pos=S.snap(pos or S.position())
  local source
  for _,row in ipairs(S.list())do if pos>row.s+0.001 and pos<row.e-0.001 then
   if source then error('Overlapping regions at this position. Adjust their bounds in REAPER first.',0)end
   source=row
  end end
  if not source then error('Place the cursor inside a section, away from its edges. Start with Use scratch take or From selection.',0)end
  local created
  M.edit('mark song transition',function()
   -- Add first so a failed creation cannot shorten the existing section.
   created=add(pos,source.e,'Section '..(#S.list()+1),source.color)
   assert(R.SetProjectMarker3(0,source.id,true,source.s,pos,source.name,source.color),'Could not shorten the existing section.')
   put('section',created.key)
   -- Marking while listening edits structure without seeking the transport.
   if S.mode()=='section'then put('mode','')end
  end)
  return created
 end
 function S.rename(key,label)
  M.stopped();label=name(label);local row=assert(S.find(key),'Choose a section first.')
  M.edit('rename song section',function()assert(R.SetProjectMarker3(0,row.id,true,row.s,row.e,label,row.color))end)
 end
 function S.resize(key,s,e)
  M.stopped();valid_range(s,e);local row=assert(S.find(key),'Choose a section first.');no_overlap(s,e,key)
  M.edit('change section bounds',function()assert(R.SetProjectMarker3(0,row.id,true,s,e,row.name,row.color))end)
  if S.mode()=='section' and get('section')==key then S.select(key)end
 end
 -- Preview a shared boundary before committing a single undoable edit.
 function S.edge_plan(key,edge,pos)
  assert(edge=='s' or edge=='e','Choose a start or end edge.')
  local row=assert(S.find(key),'This section no longer exists.')
  local all=S.list();local changes={};local old=row[edge]
  for _,other in ipairs(all)do
   local a,b=other.s,other.e
   if other.key==key then if edge=='s'then a=pos else b=pos end
   elseif edge=='s' and math.abs(other.e-old)<0.00001 then b=pos
   elseif edge=='e' and math.abs(other.s-old)<0.00001 then a=pos end
   valid_range(a,b)
   if a~=other.s or b~=other.e then changes[#changes+1]={row=other,s=a,e=b}end
   other.s=a;other.e=b
  end
  table.sort(all,function(a,b)return a.s<b.s end)
  for i=2,#all do
   if all[i].s<all[i-1].e-0.00001 then error('That edge would overlap another section.',0)end
  end
  return changes
 end
 function S.edge(key,edge,pos)
  M.stopped();local changes=S.edge_plan(key,edge,pos)
  if #changes==0 then return end
  M.edit('move section boundary',function()
   for _,change in ipairs(changes)do local row=change.row
    assert(R.SetProjectMarker3(0,row.id,true,change.s,change.e,row.name,row.color))
   end
  end)
  if S.mode()=='section' then
   for _,change in ipairs(changes)do if change.row.key==get('section')then S.select(get('section'));break end end
  end
 end
 function S.parse_position(value)
  value=tostring(value or ''):match('^%s*(.-)%s*$')
  if value:match('^%d+$')then
   local bar=tonumber(value);assert(bar>=1 and bar<=100000,'Enter a bar number starting at 1.')
   return R.TimeMap_GetMeasureInfo(0,bar-1)
  end
  assert(value:match('^%d+%.%d+$') or value:match('^%d+%.%d+%.%d+$'),'Use a bar number, or bar.beat.hundredths (for example 9.1.00).')
  local bar,beat=value:match('^(%d+)%.(%d+)');assert(tonumber(bar)>=1 and tonumber(beat)>=1,'Bar and beat numbers start at 1.')
  local t=R.parse_timestr_pos(value,2);assert(t>=0 and t<math.huge,'Enter a position within the song.');return t
 end
 function S.end_after_bars(start,bars)
  bars=tonumber(bars);assert(bars and bars>=1 and bars<=100000 and bars%1==0,'Enter a whole number of bars (1 or more).')
  local beats,measure=R.TimeMap2_timeToBeats(0,start)
  return R.TimeMap2_beatsToTime(0,beats,measure+bars)
 end
 function S.bar_position(pos)
  local beats,measure,count=R.TimeMap2_timeToBeats(0,pos)
  return measure+beats/count
 end
 function S.remove(key)
  M.stopped();local row=assert(S.find(key),'Choose a section first.')
  M.edit('remove section label',function()
   assert(R.DeleteProjectMarker(0,row.id,true))
   if get('section')==key then put('section','');put('mode','');R.Main_OnCommand(40020,0);R.Main_OnCommand(40252,0);R.GetSetRepeat(0)end
  end)
 end
 function S.manual()M.stopped();put('mode','')end
 function S.select(key)
  M.stopped();local row=assert(S.find(key),'This section is no longer in the project.')
  put('section',key);put('mode','section')
  R.GetSet_LoopTimeRange2(0,true,false,row.s,row.e,false)
  R.GetSet_LoopTimeRange2(0,true,true,row.s,row.e,false)
  R.GetSetRepeat(S.looping() and 1 or 0)
  R.Main_OnCommand(40076,0)
  R.SetEditCurPos2(0,row.s,true,R.GetPlayState()&1~=0)
 end
 function S.full_song()
  M.stopped();put('mode','full');R.Main_OnCommand(40020,0);R.GetSetRepeat(0);R.Main_OnCommand(40252,0)
  R.SetEditCurPos2(0,0,true,R.GetPlayState()&1~=0)
 end
 function S.set_loop(value)
  M.stopped();put('loop',value and '1' or '0')
  if S.mode()=='section'then R.GetSetRepeat(value and 1 or 0)end
 end
 function S.label()
  if S.mode()=='full'then return 'Full song'end
  if S.mode()=='section'then local row=S.active();return row and row.name or 'Missing section'end
  return 'Timeline selection / cursor'
 end
 function S.filter_takes(rows)
  local section=S.mode()=='section' and S.active()
  if not section then return rows end
  local filtered={}
  for _,row in ipairs(rows)do
   for _,it in ipairs(row.items)do
    local p=R.GetMediaItemInfo_Value(it,'D_POSITION');local e=p+R.GetMediaItemInfo_Value(it,'D_LENGTH')
    if p<section.e-0.00001 and e>section.s+0.00001 then filtered[#filtered+1]=row;break end
   end
  end
  return filtered
 end
 function S.cancel_watch()
  capture().restore(R.EnumProjects(-1,''))
  local token=R.GetExtState(M.ns,'section_record_job'):match('^([^\t]+)')
  R.DeleteExtState(M.ns,'section_record_job',false)
  if token then
   local i=0
   while true do local project=R.EnumProjects(i,'');if not project then break end;lead().restore(project,token);capture().restore(project,token);i=i+1 end
  end
 end
 function S.recover_leadin()local project=R.EnumProjects(-1,'');lead().recover(project);capture().recover(project)end
 function S.record_bounds(row)
  local beat,measure=R.TimeMap2_timeToBeats(0,row.s)
  local before=measure>=2 and R.TimeMap2_beatsToTime(0,beat,measure-2)or 0
  return math.max(0,before),S.end_after_bars(row.e,2)
 end
 local function check_handles(row)
  local _,metro=R.get_config_var_string('projmetroen')
  assert(tonumber(metro)and math.floor(tonumber(metro))&16==0,'Turn off Count-in before recording in Click sound / Metronome settings. The two-bar recorded lead-in supplies the count-in.')
  if row.s==0 then
   local ready,bars=R.get_config_var_string('prerollmeas')
   assert(ready and tonumber(bars)==2,'Set Pre-roll measures to 2 in Click sound / Metronome settings for recording at the start of the song.')
  end
 end
 function S.prepare_record()
  S.cancel_watch();S.recover_leadin()
  if S.mode()=='full'then
   R.OnStopButton();S.full_song();return
  elseif S.mode()=='section'then
   local row=S.active();if not row then error('The chosen section was removed. Choose another section or Full song.',0)end
   check_handles(row)
   R.OnStopButton();S.select(row.key)
   local first,last=S.record_bounds(row)
   capture().prepare(R.EnumProjects(-1,''),first,last,row.s,S.looping())
   R.GetSet_LoopTimeRange2(0,true,false,row.s,row.e,false)
   R.SetEditCurPos2(0,first,true,false)
   return not S.looping() and last or nil,row.s
  end
 end
 function S.start_watch(endpoint,punch)
  if not endpoint and not punch then return end
  local project=R.EnumProjects(-1,'')
  local prepared=capture().job(project)
  local token=prepared and prepared.token or R.genGuid()
  R.SetProjExtState(project,M.ns,'section_watch_token',token)
  R.SetExtState(M.ns,'section_record_job',token..'\t'..string.format('%.14f',endpoint or -1)..'\t'..string.format('%.14f',punch or -1),false)
  lead().begin(project,token,punch)
  local command=R.AddRemoveReaScript(true,0,dir..'/Solo Studio - Finish section recording.lua',true)
  assert(command~=0,'Could not start the section recording stop helper.')
  R.Main_OnCommand(command,0)
 end
 return S
end
