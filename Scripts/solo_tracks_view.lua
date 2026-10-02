local R=reaper
return function(M,ui)
 local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
 local T=dofile(dir..'/solo_tracks.lua')(M,{busy=ui.busy})
 local meters=dofile(dir..'/solo_track_meters.lua')()
 local V={};local C=ui.colors;local scroll,box,expanded=0,nil,{}
 local row_height=74
 local meter_green,meter_amber,meter_red={.33,.76,.55},{.93,.72,.32},{.96,.36,.39}
 local function meter(row,x,y,w)
  local state=meters.read(row);local bar_width=w-65
  for ch=1,2 do
   local cy=y+(ch-1)*7
   ui.color({.07,.09,.11});gfx.rect(x,cy,bar_width,5,1)
   local filled=bar_width*meters.position(state.level[ch])
   for _,zone in ipairs({{0,.7,meter_green},{.7,.9,meter_amber},{.9,1,meter_red}})do
    local start=bar_width*zone[1];local ending=math.min(filled,bar_width*zone[2])
    if ending>start then ui.color(zone[3]);gfx.rect(x+start,cy,ending-start,5,1)end
   end
   if state.peak[ch]>-60 then
    ui.color(C.text);gfx.rect(x+math.min(bar_width-1,bar_width*meters.position(state.peak[ch])),cy,1,5,1)
   end
  end
  local peak=math.max(state.peak[1],state.peak[2])
  ui.text(peak<=-60 and '-inf'or string.format('%+.1f',peak),x+bar_width+9,y-2,3,state.clipped and meter_red or C.muted,54)
  if state.clipped then ui.color(meter_red);gfx.rect(x+bar_width-3,y,3,12,1)end
  ui.hit(x,y-3,w,20,function()meters.clear(row.key)end,true)
  return gfx.mouse_x>=x and gfx.mouse_x<x+w and gfx.mouse_y>=y-3 and gfx.mouse_y<y+17
 end
 local function input_label(value)
  if value<0 then return 'Unassigned'end
  if value&4096~=0 then return 'MIDI'end
  if value&2048~=0 then return 'Multichannel'end
  local first=(value&1023)+1
  return value&1024~=0 and ('Input '..first..' / '..(first+1))or 'Input '..first
 end
 local function db_label(db)return db==-math.huge and '-inf dB'or string.format('%+.1f dB',db)end
 local function pan_label(pan)return math.abs(pan)<.0005 and 'Center'or string.format('%s %.0f%%',pan<0 and 'L'or 'R',math.abs(pan)*100)end
 local function rename(row)
  local project=R.EnumProjects(-1,'')
  local ok,value=R.GetUserInputs('Rename '..row.name,1,(row.id and 'Group name:'or 'Track name:')..',extrawidth=220',row.name)
  if ok then
   if row.id then T.rename_group(row,value,project)else T.rename(row.key,value,project)end
   ui.changed(row.id and 'Group renamed. Its instrument tab has the same name.'or 'Track renamed.')
  end
 end
 local function delete(row)
  local plan=row.id and T.plan_delete_group(row,R.EnumProjects(-1,''))or T.plan_delete(row.key)
  local message='Delete "'..row.name..'" and '..#plan.rows..(#plan.rows==1 and ' track?'or ' tracks?')..'\n\n'
   ..plan.items..' audio/MIDI items and '..plan.fx..' track effects will be removed from this project.\n'
   ..'Source audio files stay on disk. Cmd+Z restores the tracks and recordings.'
  if R.ShowMessageBox(message,'Delete '..#plan.rows..(#plan.rows==1 and ' track'or ' tracks'),4)==6 then
   local count=T.delete(plan);ui.changed('Deleted '..count..(count==1 and ' track.'or ' tracks.')..' Cmd+Z restores them.')
  end
 end
 local function volume(row,db,project)
  T.set_volume(row,db,project);ui.changed(row.name..': '..db_label(db)..(#row.members>1 and ' linked volume. Relative levels preserved.'or '.'))
 end
 local function volume_input(row)
  local project=R.EnumProjects(-1,'')
  local prompt=#row.members>1 and 'Loudest fader dB (-60 to +24; linked):'or 'Volume dB (-60 to +24):'
  local ok,value=R.GetUserInputs(row.name..' volume',1,prompt..',extrawidth=240',string.format('%.1f',math.max(-60,row.db)))
  if ok then volume(row,tonumber(value),project)end
 end
 local function pan(row,value,project)
  local actual=T.set_pan(row,value,project)
  ui.changed(row.name..': '..pan_label(actual)..(math.abs(actual-value)>1e-9 and ' / stereo spacing preserved at the pan limit.'or '.'))
 end
 local function pan_input(row)
  local project=R.EnumProjects(-1,'')
  local ok,value=R.GetUserInputs(row.name..' pan',1,'Pan: -100 left / 0 center / +100 right:,extrawidth=240',string.format('%.1f',row.pan*100))
  if ok then local number=tonumber(value);pan(row,number and number/100,project)end
 end
 local function live_adjustment(row,kind,project)
  return function()
   local gesture=T.begin_adjustment(row,kind,project)
   return {cancel=gesture.cancel,
    update=function(position)
     local actual=gesture.update(kind=='volume'and position*84-60 or position*2-1)
     return kind=='volume'and (actual+60)/84 or (actual+1)/2
    end,
    finish=function()
     local actual=gesture.finish()
     if actual then ui.changed(row.name..': '..(kind=='volume'and db_label(actual)or pan_label(actual))..'.')end
    end}
  end
 end
 function V.reset()scroll=0;box=nil;expanded={};meters.reset()end
 function V.wheel(delta)
  if box and gfx.mouse_x>=box.x and gfx.mouse_x<box.x+box.w and gfx.mouse_y>=box.y and gfx.mouse_y<box.y+box.h then scroll=math.max(0,scroll-delta);return true end
 end
 function V.draw(x,y,w,h,recording)
  meters.begin_frame(R.EnumProjects(-1,''),R.time_precise())
  local groups=T.groups();local rows={};local count,automated=0,false
  for _,group in ipairs(groups)do
   if not group.other then count=count+1 end
   rows[#rows+1]={row=group,group=true}
   if expanded[group.key]then for _,member in ipairs(group.members)do rows[#rows+1]={row=T.track(member),track=member}end end
  end
  local busy=ui.busy and ui.busy();local enabled=not recording and not busy
  local visible=math.max(1,math.floor((h-111)/row_height))
  scroll=math.max(0,math.min(scroll,#rows-visible));box={x=x,y=y+68,w=w,h=visible*row_height}
  ui.text('Track groups',x,y,4)
  ui.text('Expand an instrument to see its tracks. Group volume keeps their relative levels.',x+150,y+3,3,C.muted,w-285)
  ui.button('Up',x+w-118,y,50,28,function()scroll=math.max(0,scroll-1)end)
  ui.button('Down',x+w-62,y,62,28,function()scroll=scroll+1 end)
  ui.text('Instrument / track',x+48,y+43,3,C.muted)
  ui.text('Volume / peak dBFS',x+w-868,y+43,3,C.muted)
  ui.text('Pan',x+w-564,y+43,3,C.muted)
  ui.text('Mute',x+w-332,y+43,3,C.muted)
  local pan_hint,meter_hint
  for i=scroll+1,math.min(#rows,scroll+visible)do
   local entry=rows[i];local row=entry.row;local ry=box.y+(i-scroll-1)*row_height
   local selected=row.active or entry.track and entry.track.selected
   ui.color(selected and {.25,.35,.43}or entry.group and C.surface or {.14,.17,.21});gfx.rect(x,ry,w,row_height-5,1)
   if row.active then ui.color(C.blue);gfx.rect(x,ry,3,row_height-5,1)end
   if entry.group and (#row.members>1 or row.other)then
    ui.button(expanded[row.key]and '-'or '+',x+8,ry+11,28,32,function()expanded[row.key]=not expanded[row.key]end)
   end
   local name_x=x+(entry.group and 48 or 66)
   local name_width=x+w-886-name_x
   ui.text(row.name,name_x,ry+7,entry.group and 4 or 1,C.text,row.other and w-100 or name_width)
   local detail
   if entry.track then detail=input_label(entry.track.input)..' / '..entry.track.items..' items / '..entry.track.fx..' FX'
   elseif row.other then detail=#row.members..' buses and tracks outside recording groups'
   else detail=#row.members..(#row.members==1 and ' track'or ' tracks / linked levels')end
   if row.volume_automated then detail=detail..' / volume automation'end
   if row.mute_automated then detail=detail..' / mute automation'end
   if row.pan_automated then detail=detail..' / pan automation'end
   ui.text(detail,name_x,ry+33,3,C.muted,row.other and w-100 or name_width)
   if not row.other then
    local project=R.EnumProjects(-1,'');local volume_enabled=enabled and not row.volume_automated
    automated=automated or row.volume_automated or row.mute_automated or row.pan_automated
    ui.slider('track-volume:'..row.key,x+w-868,ry+16,110,(row.db+60)/84,function(value)volume(row,value*84-60,project)end,volume_enabled,false,live_adjustment(row,'volume',project))
    ui.button(row.volume_automated and 'Auto'or db_label(row.db),x+w-746,ry+11,86,32,function()volume_input(row)end,nil,volume_enabled)
    ui.button('-1',x+w-654,ry+11,30,32,function()volume(row,math.max(-60,math.min(24,row.db-1)),project)end,nil,volume_enabled and row.db>-60)
    ui.button('+1',x+w-618,ry+11,30,32,function()volume(row,math.min(24,math.max(-60,row.db+1)),project)end,nil,volume_enabled and row.db<24)
    if meter(row,x+w-868,ry+49,280)then
     meter_hint=(#row.members>1 and 'Group meter: loudest member per channel.'or 'Track meter: native REAPER levels.')
      ..' Top = left, bottom = right. Peak hold: 1.2s. Red = reached 0 dBFS. Click to clear.'
    end
    local pan_wide=row.pan_max-row.pan_min<1e-9
    local pan_enabled=enabled and not row.pan_automated and not pan_wide
    ui.slider('track-pan:'..row.key,x+w-564,ry+16,108,(row.pan+1)/2,function(value)pan(row,value*2-1,project)end,pan_enabled,true,live_adjustment(row,'pan',project))
    ui.button(row.pan_automated and 'Auto'or pan_wide and 'Wide'or pan_label(row.pan),x+w-446,ry+11,66,32,function()pan_input(row)end,nil,pan_enabled)
    ui.button('C',x+w-372,ry+11,30,32,function()pan(row,0,project)end,nil,pan_enabled and math.abs(row.pan)>1e-9)
    if gfx.mouse_x>=x+w-570 and gfx.mouse_x<x+w-342 and gfx.mouse_y>=ry and gfx.mouse_y<ry+55 then
     pan_hint=row.pan_automated and 'This pan follows an existing REAPER envelope.'
      or pan_wide and 'This group spans hard left to hard right. Expand it to adjust individual tracks; use REAPER for dual-pan width.'
      or 'Drag to pan, click the value for exact entry, or C to center. Linked pans stop at the edge to preserve their spacing.'
    end
    local mute_label=row.mute_automated and 'Auto'or row.muted and 'Muted'or row.mixed_mute and 'Mixed'or 'Mute'
    ui.button(mute_label,x+w-332,ry+11,96,32,function()T.toggle_mute(row,project);ui.changed(row.name..' mute updated.')end,row.muted and {.40,.32,.19}or nil,enabled and not row.mute_automated)
    ui.button('Rename...',x+w-226,ry+11,106,32,function()rename(row)end,nil,enabled)
    ui.button('Delete...',x+w-112,ry+11,112,32,function()delete(row)end,C.record,enabled)
    ui.hit(name_x,ry,name_width,row_height-5,function()
     if row.id then M.choose_set(row.id)
     else
      assert(R.ValidatePtr2(0,entry.track.track,'MediaTrack*'),'That track changed. Select it again.')
      M.select_tracks({entry.track.track});R.TrackList_AdjustWindows(false)
     end
     ui.changed('Selected '..row.name..'.')
    end,enabled)
   end
  end
  if #rows==0 then ui.text('Add an instrument above to create your first recording group.',x+12,box.y+12,1,C.muted,w-24)end
  local hint=meter_hint or recording and 'Live meters remain visible while recording. Finish recording to adjust groups.'or busy and 'Finish the AI mix operation to adjust groups.'or pan_hint
   or automated and 'Automated volume/pan/mute controls stay under REAPER automation. Other controls remain available.'
   or 'Volume and pan update as you drag. Each drag is one Undo step; Esc cancels. Group levels stay linked.'
  ui.text(hint,x,y+h-27,3,C.muted,w-145)
  ui.text(count..(count==1 and ' track group'or ' track groups'),x+w-140,y+h-27,3,C.muted,140)
 end
 return V
end
