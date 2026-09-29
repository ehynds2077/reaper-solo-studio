local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
return function(M,ui,options)
 local P=dofile(dir..'/solo_projects.lua')(M,options);local V={};local C=ui.colors
 local rows,selected,scroll,box={},nil,0,nil;local query='';local last_refresh=0
 local A,import_job,import_status,import_report
 local function refresh()
  P.refresh();last_refresh=R.time_precise()
 end
 local function chosen()for _,row in ipairs(rows)do if row.key==selected then return row end end end
 local function opened(row)
  P.open(row);refresh();ui.opened('Opened '..row.title..'. Previous songs remain open in REAPER tabs.')
 end
 local function new_song()
  local project=P.prompt_new()
  if project then refresh();ui.opened('New song saved and ready for scratch guitar + vocal. Choose Inputs if your interface assignments differ.')end
 end
 local function import_ableton()
  if import_job or not P.available()then return end
  local ok,path=R.GetUserFileNameForRead(P.root..'/','Import an Ableton Live set','.als')
  if not ok then return end
  A=A or dofile(dir..'/solo_ableton.lua')
  local accepted,media=R.GetUserInputs('Ableton import — media stays in place',1,'Relink folder (optional):,extrawidth=260','')
  if not accepted then return end
  import_job=A.start(path,P.root,media);import_status=nil
 end
 local function finish_import()
  if not import_status or not import_status.ok or not P.available()then return end
  assert(R.GetPlayState()==0,'Stop playback and recording before opening the imported song.')
  if options and options.before_switch then options.before_switch()end
  local _,report=A.apply(A.read_plan(import_status.plan))
  import_report=import_job.folder;import_job=nil;import_status=nil
  selected=P.add(report.project);refresh()
  ui.opened('Ableton song imported. Review the import report for missing audio and effects that need attention.')
 end
 local function add()
  local ok,path=R.GetUserFileNameForRead(P.root..'/','Add an existing REAPER song','.RPP')
  if ok then selected=P.add(path);query='';scroll=0;refresh()end
 end
 local function search()
  local ok,value=R.GetUserInputs('Find a song',1,'Song name:,extrawidth=220',query)
  if ok then query=value:lower();scroll=0;selected=nil end
 end
 local function rename()
  local row=chosen()
  if not row or row.path==''or not P.available()then return end
  local expected=R.EnumProjects(-1,'')
  local ok,value=R.GetUserInputs('Rename song in Projects',1,'Song name (files stay in place):,extrawidth=240',row.title)
  if ok then
   selected=P.rename(row,value,expected);query='';refresh()
   for i,song in ipairs(P.list())do if song.key==selected then scroll=math.max(0,i-(box and box.visible or 1));break end end
  end
 end
 function V.reset()last_refresh=0 end
 function V.wheel(delta)
  if box and gfx.mouse_y>=box.y and gfx.mouse_y<box.y+box.h then scroll=math.max(0,scroll-delta);return true end
 end
 function V.key(ch)
  if ch==110 or ch==78 then ui.run(new_song);return true end
  if ch==26162 then ui.run(rename);return true end -- F2
  if ch==13 then local row=chosen();if row then ui.run(function()opened(row)end)end;return true end
  if ch==30064 or ch==1685026670 then
   local index=1;for i,row in ipairs(rows)do if row.key==selected then index=i;break end end
   index=math.max(1,math.min(#rows,index+(ch==30064 and -1 or 1)))
   if rows[index]then selected=rows[index].key;scroll=math.max(0,index-(box and box.visible or 1))end
   return true
  end
  -- Project browsing must not trigger recording or hidden take actions.
  if ch==114 or ch==82 or ch==102 or ch==70 or ch==98 or ch==66 or ch==1818584692 or ch==1919379572 then return true end
  return false
 end
 function V.draw(x,y,w,h)
  if import_job and not import_status then import_status=A.poll(import_job)end
  if last_refresh==0 then refresh()end
  rows={};for _,row in ipairs(P.list())do if query==''or row.title:lower():find(query,1,true)then rows[#rows+1]=row end end
  if not chosen()then selected=rows[1]and rows[1].key end
  local picked=chosen();local report_folder=picked and picked.path:match('^(.*)/')
  if not report_folder or not R.file_exists(report_folder..'/Import report.md')then report_folder=import_report end
  local available=P.available();local extra=import_job and 49 or 0;local visible=math.max(1,math.floor((h-183-extra)/57))
  scroll=math.max(0,math.min(scroll,#rows-visible));box={x=x,y=y+117+extra,w=w,h=visible*57,visible=visible}
  ui.text('Your songs',x,y,2)
  ui.text(#rows..(#rows==1 and ' project'or ' projects')..'  /  Full-band X32 template',x+165,y+10,3,C.muted,w-580)
  ui.button('+ New song',x+w-174,y,174,39,new_song,C.blue,available)
  ui.button('Add existing...',x,y+48,143,32,add)
  ui.button(query~=''and ('Find: '..query)or 'Find a song...',x+153,y+48,180,32,search)
  if query~=''then ui.button('Clear',x+342,y+48,68,32,function()query='';scroll=0 end)end
  ui.button('Import Ableton...',x+422,y+48,166,32,import_ableton,nil,available and not import_job)
  if import_job then
   local label='Analyzing Live XML, plug-in states and media...'
   if import_status then
    if import_status.ok then
     local s=import_status.stats;label=s.tracks..' tracks / '..s.clips..' clips / '..s.missing_arrangement_clips..' arrangement clips need audio'
     ui.button('Open imported song',x+w-194,y+90,194,33,finish_import,C.blue,available and R.GetPlayState()==0)
    else
     label='Import analysis failed: '..import_status.error
     ui.button('Dismiss',x+w-194,y+90,194,33,function()import_report=import_job.folder;import_job=nil;import_status=nil end)
    end
   end
   ui.text(label,x+14,y+102,3,C.gold,w-340)
   ui.button('Report',x+w-290,y+90,86,33,function()A.reveal(import_job.folder)end,nil,import_status~=nil)
  elseif report_folder then
   ui.button('Import report',x+598,y+48,126,32,function()A=A or dofile(dir..'/solo_ableton.lua');A.reveal(report_folder)end)
  end
  ui.button('Refresh',x+w-270,y+48,98,32,refresh)
  ui.button('Up',x+w-162,y+48,70,32,function()scroll=math.max(0,scroll-1)end)
  ui.button('Down',x+w-82,y+48,82,32,function()scroll=scroll+1 end)
  ui.text('Song',x+14,y+94+extra,3,C.muted)
  ui.text('Status',x+w*.44,y+94+extra,3,C.muted)
  ui.text('Tempo / tracks',x+w*.66,y+94+extra,3,C.muted)
  ui.text('Last opened',x+w*.81,y+94+extra,3,C.muted)
  for i=scroll+1,math.min(#rows,scroll+visible)do
   local row=rows[i];local ry=box.y+(i-scroll-1)*57
   ui.color(row.key==selected and {.25,.35,.43}or C.surface);gfx.rect(x,ry,w,52,1)
   if row.current then ui.color(C.blue);gfx.rect(x,ry,4,52,1)end
   ui.text(row.title,x+14,ry+7,4,C.text,w*.43-24)
   ui.text(row.path~=''and (row.path:match('([^/]+)/[^/]+$')or row.path)or 'Save this song to keep it in your library',x+14,ry+32,3,C.muted,w*.43-24)
   local state=row.current and 'Current song'or row.project and 'Open in REAPER'or row.missing and 'File missing'or 'Saved'
   if row.dirty then state=state..' / unsaved edits'end
   ui.text(state,x+w*.44,ry+18,3,row.missing and C.gold or C.text,w*.21-12)
   ui.text((row.bpm and string.format('%.0f BPM',row.bpm)or '—')..' / '..(row.tracks or 0),x+w*.66,ry+18,3,C.muted,w*.15-12)
   ui.text(row.last_opened>0 and os.date('%b %d, %Y',row.last_opened)or '—',x+w*.81,ry+18,3,C.muted,w*.19-14)
   ui.hit(x,ry,w,52,function()selected=row.key end,true)
  end
  if #rows==0 then ui.text(query~=''and 'No matching songs. Clear the search to see all projects.'or 'Start a new song, or add a saved REAPER project.',x+16,box.y+18,1,C.muted,w-32)end
  local row=chosen();local bottom=y+h-56
  ui.text(row and (row.path~=''and row.path or 'Unsaved project — use Save project above.')or P.root,x,bottom,3,C.muted,w-332)
  ui.text(available and 'N: new song   F2: rename   Enter: open song   Unsaved edits stay open.'or 'Finish recording or the current AI mix operation to switch songs.',x,bottom+28,3,C.muted,w-332)
  ui.button('Rename...',x+w-310,bottom,126,43,rename,nil,available and row~=nil and row.path~='')
  ui.button(row and row.current and 'Back to song'or 'Open song',x+w-174,bottom,174,43,function()if row then opened(row)end end,C.blue,available and row~=nil and not row.missing)
 end
 return V
end
