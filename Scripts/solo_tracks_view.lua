local R=reaper
return function(M,ui)
 local T=dofile(debug.getinfo(1,'S').source:sub(2):match('^(.*)/')..'/solo_tracks.lua')(M,{busy=ui.busy})
 local V={};local C=ui.colors;local scroll,box,expanded=0,nil,{}
 local function input_label(value)
  if value<0 then return 'Unassigned'end
  if value&4096~=0 then return 'MIDI'end
  if value&2048~=0 then return 'Multichannel'end
  local first=(value&1023)+1
  return value&1024~=0 and ('Input '..first..' / '..(first+1))or 'Input '..first
 end
 local function db_label(db)return db==-math.huge and '-inf dB'or string.format('%+.1f dB',db)end
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
 function V.reset()scroll=0;box=nil;expanded={}end
 function V.wheel(delta)
  if box and gfx.mouse_x>=box.x and gfx.mouse_x<box.x+box.w and gfx.mouse_y>=box.y and gfx.mouse_y<box.y+box.h then scroll=math.max(0,scroll-delta);return true end
 end
 function V.draw(x,y,w,h,recording)
  local groups=T.groups();local rows={};local count,automated=0,false
  for _,group in ipairs(groups)do
   if not group.other then count=count+1 end
   rows[#rows+1]={row=group,group=true}
   if expanded[group.key]then for _,member in ipairs(group.members)do rows[#rows+1]={row=T.track(member),track=member}end end
  end
  local busy=ui.busy and ui.busy();local enabled=not recording and not busy
  local visible=math.max(1,math.floor((h-111)/60))
  scroll=math.max(0,math.min(scroll,#rows-visible));box={x=x,y=y+68,w=w,h=visible*60}
  ui.text('Track groups',x,y,4)
  ui.text('Expand an instrument to see its tracks. Group volume keeps their relative levels.',x+150,y+3,3,C.muted,w-285)
  ui.button('Up',x+w-118,y,50,28,function()scroll=math.max(0,scroll-1)end)
  ui.button('Down',x+w-62,y,62,28,function()scroll=scroll+1 end)
  ui.text('Instrument / track',x+48,y+43,3,C.muted)
  ui.text('Volume',x+w-692,y+43,3,C.muted)
  ui.text('Mute',x+w-332,y+43,3,C.muted)
  for i=scroll+1,math.min(#rows,scroll+visible)do
   local entry=rows[i];local row=entry.row;local ry=box.y+(i-scroll-1)*60
   local selected=row.active or entry.track and entry.track.selected
   ui.color(selected and {.25,.35,.43}or entry.group and C.surface or {.14,.17,.21});gfx.rect(x,ry,w,55,1)
   if row.active then ui.color(C.blue);gfx.rect(x,ry,3,55,1)end
   if entry.group and (#row.members>1 or row.other)then
    ui.button(expanded[row.key]and '-'or '+',x+8,ry+11,28,32,function()expanded[row.key]=not expanded[row.key]end)
   end
   local name_x=x+(entry.group and 48 or 66)
   ui.text(row.name,name_x,ry+7,entry.group and 4 or 1,C.text,w-772)
   local detail
   if entry.track then detail=input_label(entry.track.input)..' / '..entry.track.items..' items / '..entry.track.fx..' FX'
   elseif row.other then detail=#row.members..' buses and tracks outside recording groups'
   else detail=#row.members..(#row.members==1 and ' track'or ' tracks / linked levels')end
   if row.volume_automated then detail=detail..' / volume automation'end
   if row.mute_automated then detail=detail..' / mute automation'end
   ui.text(detail,name_x,ry+33,3,C.muted,w-772)
   if not row.other then
    local project=R.EnumProjects(-1,'');local volume_enabled=enabled and not row.volume_automated
    automated=automated or row.volume_automated or row.mute_automated
    ui.slider('track-volume:'..row.key,x+w-692,ry+16,168,(row.db+60)/84,function(value)volume(row,value*84-60,project)end,volume_enabled)
    ui.button(row.volume_automated and 'Auto'or db_label(row.db),x+w-508,ry+11,92,32,function()volume_input(row)end,nil,volume_enabled)
    ui.button('-1',x+w-408,ry+11,30,32,function()volume(row,math.max(-60,math.min(24,row.db-1)),project)end,nil,volume_enabled and row.db>-60)
    ui.button('+1',x+w-372,ry+11,30,32,function()volume(row,math.min(24,math.max(-60,row.db+1)),project)end,nil,volume_enabled and row.db<24)
    local mute_label=row.mute_automated and 'Auto'or row.muted and 'Muted'or row.mixed_mute and 'Mixed'or 'Mute'
    ui.button(mute_label,x+w-332,ry+11,96,32,function()T.toggle_mute(row,project);ui.changed(row.name..' mute updated.')end,row.muted and {.40,.32,.19}or nil,enabled and not row.mute_automated)
    ui.button('Rename...',x+w-226,ry+11,106,32,function()rename(row)end,nil,enabled)
    ui.button('Delete...',x+w-112,ry+11,112,32,function()delete(row)end,C.record,enabled)
    ui.hit(name_x,ry,w-760,55,function()
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
  local hint=recording and 'Finish recording to adjust groups.'or busy and 'Finish the AI mix operation to adjust groups.'
   or automated and 'Automated volume/mute controls stay under REAPER automation. Other controls remain available.'
   or 'Group dB shows its loudest fader; all member levels move together. Changes apply on release and support Undo.'
  ui.text(hint,x,y+h-27,3,C.muted,w-145)
  ui.text(count..(count==1 and ' track group'or ' track groups'),x+w-140,y+h-27,3,C.muted,140)
 end
 return V
end
