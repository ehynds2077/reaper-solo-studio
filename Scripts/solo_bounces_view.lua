local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local B=dofile(dir..'/solo_bounces.lua');local R=reaper
return function(ui)
 local V={};local text,button,color,C=ui.text,ui.button,ui.color,ui.colors
 local P=dofile(dir..'/solo_bounce_player.lua')(B)
 local rows={};local selected;local scroll=0;local lastpoll=-10;local project;local exporting=false;local selection_scope=false
 local status='Every bounce saves a full mix, an instrumental, and a REAPER session snapshot.'
 local function refresh()
  local current=R.EnumProjects(-1,'')
  if current~=project then project=current;selected=nil;scroll=0;P.stop()end
  rows=B.list();if not selected and rows[1]then selected=rows[1].id end
 end
 local function chosen()for _,row in ipairs(rows)do if row.id==selected then return row end end end
 function V.poll()
  P.poll();if R.time_precise()-lastpoll<1 then return end;lastpoll=R.time_precise();refresh()
 end
 function V.busy()return exporting end
 local function export()
  assert(not ui.busy(),'Wait for the AI mixing pass to finish before bouncing.')
  assert(R.GetPlayState()==0,'Stop playback and recording before bouncing.')
  P.stop()
  local ok,title=R.GetUserInputs('Bounce full mix + instrumental',1,'Version name:,extrawidth=240','Mix '..string.format('%02d',#rows+1))
  if not ok then return end
  local noted,notes=R.GetUserInputs('Version notes',1,'What changed? (optional):,extrawidth=350','')
  if not noted then return end
  local bounds
  if selection_scope then local a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false);assert(b>a,'Select a time range first.');bounds={a,b}end
  exporting=true
  local success,result=xpcall(function()return B.export({title=title,notes=notes,bounds=bounds})end,debug.traceback)
  exporting=false;refresh()
  if not success then error(result,0)end
  selected=result.id;status='Both renders are saved. Preparing the session archive and M4A phone copies…'
 end
 local function vocals()
  local rows=B.vocals();local labels={}
  for _,row in ipairs(rows)do labels[#labels+1]=(row.excluded and '!'or '')..row.name:gsub('[|#!<>]',' ')end
  local choice=gfx.showmenu(table.concat(labels,'|'))
  if rows[choice]then B.set_vocal(rows[choice].id,not rows[choice].excluded)end
 end
 local function clock(seconds)seconds=math.floor(seconds or 0);return string.format('%d:%02d',seconds//60,seconds%60)end
 function V.draw(x,y,w,h)
  V.poll();local idle=R.GetPlayState()==0 and not ui.busy()
  button('Bounce mix + instrumental',x,y,242,36,export,C.blue,idle)
  button(selection_scope and 'Range: selection'or 'Range: full song',x+253,y,185,36,function()selection_scope=not selection_scope end)
  button('Vocal tracks…',x+449,y,155,36,vocals,nil,idle)
  button('Desktop folder',x+w-151,y,151,36,function()B.reveal()end)
  local names={};for _,row in ipairs(B.vocals())do if row.excluded then names[#names+1]=row.name end end
  text(#names>0 and ('Instrumental leaves out: '..table.concat(names,', '))or 'No vocals selected. Both exports will sound the same; choose Vocal tracks to change this.',x,y+48,3,#names>0 and C.muted or C.gold,w)
  local top=y+78;local bottom=y+h-142;local visible=math.max(1,math.floor((bottom-top)/42))
  scroll=math.max(0,math.min(scroll,#rows-visible))
  if #rows==0 then
   text('Save your first mix version',x+12,top+12,4)
   text('48 kHz / 24-bit WAVs + M4As for your phone. Session copies include preserved recordings.',x+12,top+48,3,C.muted,w-24)
  end
  for i=scroll+1,math.min(#rows,scroll+visible)do
   local row=rows[i];local rowy=top+(i-scroll-1)*42
   button(row.title,x,rowy,260,36,function()selected=row.id;P.stop()end,row.id==selected and C.blue or nil)
   text(os.date('%b %d, %H:%M',row.created_at),x+275,rowy+10,3,C.muted,150)
   text(row.status=='ready'and (clock(row.duration)..'  ·  Full + instrumental')or (row.detail or row.status),x+430,rowy+10,3,row.status=='failed'and C.gold or C.muted,w-440)
  end
  local row=chosen();local by=y+h-129
  color(C.line);gfx.line(x,by-10,x+w,by-10)
  if row then
   local ready=row.status=='ready';local player=P.state();local playing=player and player.id==row.id and (player.state=='playing'or player.state=='paused'or player.state=='starting')
   button('Play full',x,by,104,32,function()P.play(row,'full')end,playing and player.variant=='full'and C.blue or nil,ready and idle)
   button('Instrumental',x+114,by,130,32,function()P.play(row,'instrumental')end,playing and player.variant=='instrumental'and C.blue or nil,ready and idle)
   button(playing and player.state=='paused'and 'Resume'or 'Pause',x+254,by,86,32,P.pause,nil,playing)
   button('Stop',x+350,by,74,32,P.stop,nil,playing)
   button('Show files',x+438,by,110,32,function()B.reveal(row)end)
   button('Open session copy',x+560,by,174,32,function()P.stop();B.open_session(row)end,nil,ready and idle)
   if row.status=='failed'then button('Retry archive',x+745,by,140,32,function()B.retry(row);lastpoll=-10 end,nil,idle)end
   local note=row.notes~=''and row.notes or 'No version notes.'
   text(note,x,by+45,3,C.text,w)
   text(playing and ('Listening: '..clock(player.position)..' / '..clock(row.duration)..'  ·  Mac audio output')or (row.detail or 'Ready'),x,by+72,3,C.muted,w)
   if player and player.state=='failed'then text(player.message,x,by+96,3,C.gold,w)
   else text(ready and 'Text the M4A files from Show files. Opening a session copy leaves your working song in its own tab.'or 'Only complete archives become playable versions.',x,by+96,3,C.muted,w)end
  else text(status,x,by+12,3,C.muted,w)end
 end
 function V.key(ch)
  if ch==32 and R.GetPlayState()==0 then ui.run(function()
   local state=P.state();if state and (state.state=='playing'or state.state=='paused')then P.pause()
   else local row=chosen();if row and row.status=='ready'and not ui.busy()then P.play(row,'full')end end
  end);return true end
  return false
 end
 function V.wheel(delta)scroll=math.max(0,scroll-delta)end
 function V.close()P.stop()end
 function V.stop()P.stop()end
 return V
end
