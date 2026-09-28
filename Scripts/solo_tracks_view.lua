local R=reaper
return function(M,ui)
 local T=dofile(debug.getinfo(1,'S').source:sub(2):match('^(.*)/')..'/solo_tracks.lua')(M)
 local V={};local C=ui.colors;local scroll,box=0,nil
 local function input_label(value)
  if value<0 then return 'Unassigned'end
  if value&4096~=0 then return 'MIDI'end
  if value&2048~=0 then return 'Multichannel'end
  local first=(value&1023)+1
  return value&1024~=0 and ('Input '..first..' / '..(first+1))or 'Input '..first
 end
 local function rename(row)
  local project=R.EnumProjects(-1,'')
  local ok,value=R.GetUserInputs('Rename '..row.name,1,'Track name:,extrawidth=220',M.track_name(row.track))
  if ok then T.rename(row.key,value,project);ui.changed('Track renamed. Single-track recording sets follow the new name.')end
 end
 local function delete(row)
  local plan=T.plan_delete(row.key)
  local message='Delete "'..row.name..'"'..(#plan.rows>1 and (' and its '..(#plan.rows-1)..' child tracks')or '')..'?\n\n'
   ..plan.items..' audio/MIDI items and '..plan.fx..' track effects will be removed from this project.\n'
   ..'Source audio files stay on disk. Cmd+Z in REAPER restores the tracks and recordings.'
  if R.ShowMessageBox(message,'Delete '..#plan.rows..(#plan.rows==1 and ' track'or ' tracks'),4)==6 then
   local count=T.delete(plan);ui.changed('Deleted '..count..(count==1 and ' track.'or ' tracks.')..' Cmd+Z in REAPER restores them.')
  end
 end
 function V.reset()scroll=0;box=nil end
 function V.wheel(delta)
  if box and gfx.mouse_x>=box.x and gfx.mouse_x<box.x+box.w and gfx.mouse_y>=box.y and gfx.mouse_y<box.y+box.h then scroll=math.max(0,scroll-delta);return true end
 end
 function V.draw(x,y,w,h,recording)
  local rows=T.list();local visible=math.max(1,math.floor((h-111)/54))
  scroll=math.max(0,math.min(scroll,#rows-visible));box={x=x,y=y+68,w=w,h=visible*54}
  ui.text('Project tracks',x,y,4)
  ui.text('Click a row to select it in REAPER. Rename or delete individual tracks here.',x+165,y+3,3,C.muted,w-310)
  ui.button('Up',x+w-118,y,50,28,function()scroll=math.max(0,scroll-1)end)
  ui.button('Down',x+w-62,y,62,28,function()scroll=scroll+1 end)
  ui.text('Track',x+12,y+43,3,C.muted)
  ui.text('Recording set',x+w*0.33,y+43,3,C.muted)
  ui.text('Input',x+w*0.55,y+43,3,C.muted)
  ui.text('Items / FX',x+w*0.68,y+43,3,C.muted)
  for i=scroll+1,math.min(#rows,scroll+visible)do
   local row=rows[i];local ry=box.y+(i-scroll-1)*54
   ui.color(row.selected and {0.25,0.35,0.43}or C.surface);gfx.rect(x,ry,w,49,1)
   local indent=math.min(row.depth,6)*14;local names={}
   for _,set in ipairs(row.sets)do names[#names+1]=set.name end
   ui.text(row.name,x+12+indent,ry+6,1,C.text,w*0.33-28-indent)
   ui.text('#'..row.index..(row.folder and ' / Folder'or row.depth>0 and ' / Folder track'or ''),x+12+indent,ry+28,3,C.muted,w*0.33-28-indent)
   ui.text(#names>0 and table.concat(names,', ')or 'No recording set',x+w*0.33,ry+16,3,C.muted,w*0.21-12)
   ui.text(input_label(row.input),x+w*0.55,ry+16,3,C.text,w*0.12-10)
   ui.text(row.items..' / '..row.fx,x+w*0.68,ry+16,3,C.text,w*0.1-10)
   ui.button('Rename...',x+w-226,ry+8,106,32,function()rename(row)end,nil,not recording)
   ui.button('Delete...',x+w-112,ry+8,112,32,function()delete(row)end,C.record,not recording)
   ui.hit(x,ry,w-236,49,function()
    assert(R.ValidatePtr2(0,row.track,'MediaTrack*'),'That track changed. Select it again.')
    M.select_tracks({row.track});R.TrackList_AdjustWindows(false)
   end,not recording)
  end
  if #rows==0 then ui.text('Add an instrument above to create your first recording track.',x+12,box.y+12,1,C.muted,w-24)end
  ui.text(recording and 'Finish recording to rename or delete tracks.'or 'Folder deletion includes its child tracks. Source audio stays on disk; track changes support REAPER Undo.',x,y+h-27,3,C.muted,w-160)
  ui.text(#rows..' project tracks',x+w-150,y+h-27,3,C.muted,150)
 end
 return V
end
