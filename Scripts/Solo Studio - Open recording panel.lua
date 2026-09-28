local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(dir..'/solo_core.lua')
local T=dofile(dir..'/solo_tempo.lua')
local S=M.sections()
local R=reaper
local C={bg={0.16,0.18,0.21},surface={0.21,0.24,0.28},line={0.32,0.36,0.40},text={0.93,0.94,0.95},muted={0.67,0.72,0.77},blue={0.35,0.58,0.76},record={0.73,0.34,0.39},gold={0.91,0.72,0.35}}
local selection=dofile(dir..'/solo_take_selection.lua')()
local mouse_down,scroll=false,0
local review_focus
local status='Drag in the song timeline to add a section, or use New section... for an exact start and length.'
local lastproject,rows,tracks,lastrefresh=nil,{},{},0
local all_rows,lastset,was_recording={},nil,false
local buttons={}
local sliders,drag={},nil
local section_scroll,sections=0,{}
local saved_view=R.GetExtState(M.ns,'panel_view')
local view=(saved_view=='review' or saved_view=='mix') and saved_view or 'timeline'
local V,X
local function color(c) gfx.set(c[1],c[2],c[3],1) end
local function text(s,x,y,font,c,w)
 gfx.setfont(font or 1); color(c or C.text);gfx.x=x;gfx.y=y
 if w then gfx.drawstr(s,0,x+w,y+35) else gfx.drawstr(s) end
end
local function run(fn,msg)
 local ok,err=pcall(fn)
 if ok then if msg then status=msg end else status=tostring(err):match('^[^\n]+') or tostring(err);M.message(status) end
 lastrefresh=0
end
local function candidates()return view=='timeline' and all_rows or rows end
local function selected_rows()return selection.rows(candidates())end
local function chosen()return selection.chosen(candidates())end
local function select_take(row)
 selection.click(candidates(),row.key,gfx.mouse_cap&4~=0,gfx.mouse_cap&8~=0)
 local count=#selected_rows()
 status=count==1 and ('Selected '..chosen().name..'. Audition to listen, or Delete take to remove the whole pass.')
  or count..' takes selected. Cmd-click toggles a take; Shift-click selects a range.'
end
local function with_row(fn)
 local selected=selected_rows();assert(#selected==1,'Select one take for this action.')
 fn(selected[1])
end
local function button(label,x,y,w,h,fn,tint,enabled)
 enabled=enabled~=false
 local hover=gfx.mouse_x>=x and gfx.mouse_x<x+w and gfx.mouse_y>=y and gfx.mouse_y<y+h
 local c=tint or C.surface
 color(hover and enabled and {math.min(c[1]+0.07,1),math.min(c[2]+0.07,1),math.min(c[3]+0.07,1)} or c)
 gfx.rect(x,y,w,h,1)
 gfx.setfont(1);local tw,th=gfx.measurestr(label)
 text(label,x+math.max(8,(w-tw)/2),y+(h-th)/2,1,enabled and C.text or C.muted,w-16)
 if enabled then buttons[#buttons+1]={x=x,y=y,w=w,h=h,fn=fn} end
end
local function mix()
 if not X then X=dofile(dir..'/solo_mix.lua')(M,{colors=C,text=text,button=button,color=color,run=run}) end
 return X
end
local function slider(id,x,y,w,value,fn,enabled)
 enabled=enabled~=false
 value=drag and drag.id==id and drag.value or value
 value=math.max(0,math.min(1,value))
 color(C.line);gfx.rect(x,y+9,w,4,1)
 color(enabled and C.blue or C.muted);gfx.rect(x,y+9,w*value,4,1)
 gfx.circle(x+w*value,y+11,6,1)
 if enabled then sliders[#sliders+1]={id=id,x=x,y=y,w=w,h=23,fn=fn} end
end
local function tempo_input()
 local ok,s=R.GetUserInputs('Song tempo',1,'Tempo (20-300 BPM):',string.format('%.2f',T.bpm()))
 if ok then T.set_bpm(tonumber(s));status='Song tempo updated.' end
end
local function click_input()
 local db=T.click_db()
 local ok,s=R.GetUserInputs('Click volume',1,'Volume (-60 to 0 dB):',string.format('%.1f',db and db>-60 and math.min(0,db) or -12))
 if ok then T.set_click_db(tonumber(s));status='Click volume updated.' end
end
local function name_set()
 local t=M.selected();if #t==0 then error('Select a track or the microphone tracks for one instrument in REAPER first.',0) end
 local ok,name=R.GetUserInputs('Name this recording set',1,'Instrument or performance:,extrawidth=180',#t==1 and M.track_name(t[1]) or 'Drums')
 if ok and name~='' then M.capture(name);selection.reset();status='Recording set saved. Its microphone lanes must represent matching passes.' end
end
local function add_instrument()
 local n=gfx.showmenu('Vocals|Guitar|Bass|Drums (several microphones)')
 local kinds={'Vocals','Guitar','Bass','Drums'};local kind=kinds[n];if not kind then return end
 local names
 if kind=='Drums' then
  local ok,s=R.GetUserInputs('Drum microphone tracks',1,'Names separated by semicolons:,extrawidth=280','Kick;Snare;Overhead L;Overhead R')
  if not ok then return end
  names={};for name in s:gmatch('[^;]+') do name=name:match('^%s*(.-)%s*$');if name~='' then names[#names+1]=name end end
  if #names==0 or #names>32 then error('Enter between 1 and 32 microphone names.',0) end
 end
 M.add_instrument(kind,names);selection.reset();status=kind..' added. Choose Inputs before recording.'
end
local function inputs()
 local ts=M.require_tracks();local n=R.GetNumAudioInputs()
 if n==0 then error('REAPER has no audio inputs. Connect your interface and choose it in REAPER > Settings > Audio > Device.',0) end
 local lines={'Available mono inputs:'};for i=0,n-1 do lines[#lines+1]=(i+1)..': '..R.GetInputChannelName(i) end
 local labels,defaults={},{}
 for _,tr in ipairs(ts) do labels[#labels+1]=M.track_name(tr);defaults[#defaults+1]=tostring(math.max(1,R.GetMediaTrackInfo_Value(tr,'I_RECINPUT')+1)) end
 M.message(table.concat(lines,'\n')..'\n\nNext, enter input numbers in this order:\n'..table.concat(labels,'; '))
 local ok,s=R.GetUserInputs('Assign inputs: '..table.concat(labels,' / '),1,'Input numbers separated by semicolons:,extrawidth=260',table.concat(defaults,';'))
 if ok then local values={};for v in s:gmatch('[^;]+') do values[#values+1]=tonumber(v) or -1 end;M.inputs(values);status='Inputs assigned. Arm set when you are ready.' end
end
local function annotate(section)
 with_row(function(row)
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  if section and e<=s then error('Select a passage first to attach a section note.',0) end
  local previous=section and M.section_note(row.lane,s,e) or row.note
  local ok,note=R.GetUserInputs(section and 'Note for this passage' or 'Note for this take',1,'Your note:,extrawidth=320',previous)
  if ok then M.note(row.lane,note,section and {s,e} or nil);status='Note saved with this project.' end
 end)
end
local function rename()
 with_row(function(row)
  local ok,name=R.GetUserInputs('Rename take across the recording set',1,'Take name:,extrawidth=220',row.name)
  if ok and name~='' then M.edit('rename take',function() for _,tr in ipairs(M.require_tracks()) do R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..row.lane,name,true) end end) end
 end)
end
local function take_action(action)
 if action=='delete' then
  local selected=selected_rows();assert(#selected>0,'Select at least one take to delete.')
  local before={};for i,row in ipairs(candidates())do before[i]=row end
  M.delete_takes(selected)
  selection.after_delete(before,selected)
  all_rows=M.lanes();rows=S.filter_takes(all_rows);selection.sync(candidates())
  status='Deleted '..#selected..(#selected==1 and ' take' or ' takes')..' across the recording set. Audio files kept. Cmd+Z in REAPER restores them.'
  return
 end
 if action=='note' then annotate(false);return end
 if action=='rename' then rename();return end
 with_row(function(row)
  if action=='audition' then M.audition(row.lane);status='Auditioning '..row.name..' across the recording set.'
  elseif action=='favorite' then M.favorite(row.lane)
  elseif action=='comp' then M.comp(row.lane);status='Passage copied to the native comp lane. Cmd+Z undoes this edit.'
  end
 end)
end
local function play()
 if R.GetPlayState()~=0 then M.stop() else R.OnPlayButton() end
end
local function select_step(d)
 M.step(d);all_rows=M.lanes();rows=S.filter_takes(all_rows);for _,row in ipairs(rows) do if row.playing then selection.only(row.key) end end
end
local function monitoring()
 local ts=M.require_tracks();local on=R.GetMediaTrackInfo_Value(ts[1],'I_RECMON')==0
 M.edit('input monitoring',function()for _,tr in ipairs(ts) do R.SetMediaTrackInfo_Value(tr,'I_RECMON',on and 1 or 0) end end)
 status=on and 'Software monitoring on. Use headphones while recording microphones.' or 'Software monitoring off. Use interface monitoring if needed.'
end
local function mark_transition()
 local row=S.split();status='Transition marked. Rename '..row.name..' when you are ready.'
end
local function change_view(value)
 view=value;selection.sync(candidates());drag=nil;V.cancel();R.SetExtState(M.ns,'panel_view',value,true)
end
local function section_sidebar(x,w,recording)
 button('Edit song timeline',x,212,w,36,function()change_view('timeline')end,C.blue)
 local list_y=286;local visible=math.max(1,math.floor((gfx.h-120-list_y)/48))
 section_scroll=math.max(0,math.min(section_scroll,#sections-visible))
 text('Song sections',x,260,4)
 local active=S.active()
 if #sections==0 then
  text('Open Song timeline to draw',x,312,1,C.muted)
  text('a section or enter its length.',x,338,1,C.muted)
 else for i=section_scroll+1,math.min(#sections,section_scroll+visible)do
  local row=sections[i];local y=list_y+(i-section_scroll-1)*48
  color(active and active.key==row.key and {0.25,0.35,0.43}or C.surface);gfx.rect(x,y,w,43,1)
  text(row.name,x+10,y+5,1,C.text,w-20)
  text(R.format_timestr_pos(row.s,'',2)..' - '..R.format_timestr_pos(row.e,'',2),x+10,y+26,3,C.muted,w-20)
  if not recording then buttons[#buttons+1]={x=x,y=y,w=w,h=43,fn=function()S.select(row.key);selection.reset();scroll=0;status='Ready for '..row.name..'.'end}end
 end end
 text('Click a section to record or comp it.',x,gfx.h-94,3,C.muted)
end
V=dofile(dir..'/solo_timeline.lua')(M,S,{colors=C,text=text,button=button,color=color,run=run,
 changed=function(message)status=message;lastrefresh=0;selection.reset();scroll=0 end,
 rows=function()return all_rows end,chosen=chosen,take_action=take_action,
 selected=selection.has,selection_count=function()return #selected_rows()end,select=select_take})
local function refresh()
 local proj=R.EnumProjects(-1,'')
 if proj~=lastproject then S.recover_leadin();selection.reset();scroll=0;section_scroll=0;drag=nil;V.reset();review_focus=nil;lastset=nil;was_recording=false;lastproject=proj;lastrefresh=0 end
 local recording=R.GetPlayState()&4~=0
 if R.time_precise()-lastrefresh>0.25 or recording~=was_recording then
  local set=M.get('active');local previous={}
  if set~=lastset then selection.reset();review_focus=nil end
  if set==lastset then for _,row in ipairs(all_rows)do previous[row.key]=true end end
  tracks=M.tracks();all_rows=M.lanes();rows=S.filter_takes(all_rows);sections=S.list()
  if was_recording and not recording and set==lastset then
   for _,row in ipairs(all_rows)do if not previous[row.key] then selection.only(row.key) end end
   -- REAPER may expose the growing lane before Stop, so prefer its playing pass.
   local focus=chosen()
   if not focus or previous[focus.key] then for _,row in ipairs(all_rows)do if row.playing then selection.only(row.key) end end end
  end
  lastset=set;lastrefresh=R.time_precise()
 end
 was_recording=recording
 selection.sync(candidates())
end
gfx.init('Solo Studio | Record & review',1200,730,tonumber(R.GetExtState(M.ns,'dock')) or 0)
gfx.setfont(1,'Helvetica',16);gfx.setfont(2,'Helvetica',28,98);gfx.setfont(3,'Helvetica',13);gfx.setfont(4,'Helvetica',19,98)
R.atexit(function()if X then X.close() end;R.SetExtState(M.ns,'dock',tostring(gfx.dock(-1)),true) end)
local function frame()
 refresh();if X then X.poll() end;buttons={};sliders={};color(C.bg);gfx.rect(0,0,gfx.w,gfx.h,1)
 if gfx.w<1180 or gfx.h<(view=='timeline' and 710 or 650) then
  V.reset()
  text('Make this panel at least 1180 x 710 to show the song timeline.',20,25,1)
 else
  local w=gfx.w-300;local active=M.get('active');local recording=R.GetPlayState() & 4 ~= 0
  text('Solo Studio',24,20,2)
  text(recording and 'Recording' or (#tracks>0 and M.get('set.'..active..'.name')..'  /  '..#tracks..' track'..(#tracks>1 and 's' or '') or 'Your recording workspace'),25,57,3,recording and C.gold or C.muted)
  button('Tuner',w-308,24,72,32,function()dofile(dir..'/solo_tuner.lua').open() end)
  button('Save project',w-225,24,115,32,function()R.Main_OnCommand(40026,0) end)
  button('Dock',w-98,24,72,32,function()gfx.dock(gfx.dock(-1)&1==1 and 0 or 1) end)
  local record_label=S.mode()=='section' and 'Record section' or (S.mode()=='full' and 'Record full song' or 'Record')
  button(recording and 'Stop & keep' or record_label,24,88,160,49,function()M.record() end,C.record)
  button(R.GetPlayState()~=0 and 'Stop' or 'Play',195,88,115,49,play)
  button('Another take',321,88,160,49,function()M.another() end)
  button('Arm set',492,88,109,49,function()M.arm();status='Only this recording set is armed.' end)
  button('Inputs...',612,88,105,49,inputs)
  local mon=#tracks>0 and R.GetMediaTrackInfo_Value(tracks[1],'I_RECMON')>0
  button(mon and 'Monitor on' or 'Monitor off',728,88,w-752,49,monitoring)
  local setlist=M.sets();local x=24
  if #setlist>4 then
   button('Recording set: '..M.get('set.'..active..'.name'),24,152,w-356,33,function()
    local labels={};for _,set in ipairs(setlist) do labels[#labels+1]=set.name:gsub('[|#!<>]',' ') end
    local index=gfx.showmenu(table.concat(labels,'|'));if setlist[index] then M.choose_set(setlist[index].id);selection.reset();scroll=0 end
   end,C.blue)
  else for _,set in ipairs(setlist) do
   local sw=math.min(148,math.max(85,(w-356)/math.max(1,#setlist)-7))
   button(set.name,x,152,sw,33,function()M.choose_set(set.id);selection.reset();scroll=0 end,set.id==active and C.blue or nil);x=x+sw+7
   if x>w-320 then break end
  end end
  button('Use selected tracks',w-308,152,169,33,name_set)
  button('+ Instrument',w-130,152,106,33,add_instrument)
  color(C.line);gfx.line(24,201,w-24,201)
  local sx=w+12
  button('Timeline',sx,24,88,33,function()change_view('timeline')end,view=='timeline' and C.blue or nil)
  button('Takes',sx+96,24,80,33,function()change_view('review')end,view=='review' and C.blue or nil)
  button('Mix',sx+184,24,80,33,function()change_view('mix')end,view=='mix' and C.blue or nil)
  text('Record: '..S.label(),sx,73,3,C.muted,264)
  button('Full song',sx,101,264,33,function()S.full_song();status='Ready to record the whole song. Stop & keep when finished.'end,S.mode()=='full' and C.blue or nil,not recording)
  button('One pass',sx,152,128,33,function()S.set_loop(false)end,not S.looping() and C.blue or nil,not recording)
  button('Loop takes',sx+136,152,128,33,function()S.set_loop(true)end,S.looping() and C.blue or nil,not recording)
  if view=='timeline' then
   V.draw(24,215,gfx.w-48,gfx.h-300,recording)
  elseif view=='mix' then
   mix().draw(24,215,gfx.w-48,gfx.h-300)
  else
  local tempo_enabled=T.tempo_enabled()
  local bpm=drag and drag.id=='tempo' and math.floor(T.min_bpm+drag.value*(T.max_bpm-T.min_bpm)+0.5) or T.bpm()
  local bpm_label=string.format(bpm%1==0 and '%.0f BPM' or '%.2f BPM',bpm)
  text('Tempo',24,220,4)
  button(bpm_label,104,211,117,32,tempo_input,nil,tempo_enabled)
  text(recording and 'Locked while recording' or (tempo_enabled and '20' or 'Tempo map in REAPER'),24,269,3,C.muted)
  if tempo_enabled then text('300',345,269,3,C.muted) end
  slider('tempo',30,245,334,(T.bpm()-T.min_bpm)/(T.max_bpm-T.min_bpm),function(value)
   T.set_bpm(math.floor(T.min_bpm+value*(T.max_bpm-T.min_bpm)+0.5));status='Song tempo updated.'
  end,tempo_enabled)
  local db=drag and drag.id=='volume' and T.position_db(drag.value) or T.click_db()
  text('Click volume',400,220,4)
  button(T.format_db(db),541,211,109,32,click_input,nil,T.click_db()~=nil)
  slider('volume',406,245,238,T.volume_position(),function(value)
   T.set_volume(value);status='Click volume: '..T.format_db(T.click_db())
  end,T.click_db()~=nil)
  text('Mute',400,269,3,C.muted);text('0 dB',624,269,3,C.muted)
  button('Click sound...',680,211,w-704,36,function()
   T.sound_settings();status='Click sound: choose a waveform, pitch, or custom sample in REAPER.'
  end)
  text('Tone or custom sample',680,258,3,C.muted)
  color(C.line);gfx.line(24,290,w-24,290)
  text('Passage',24,309,4)
  button('4 bars',122,300,78,34,function()M.loop_bars(4) end)
  button('8 bars',208,300,78,34,function()M.loop_bars(8) end)
  button('Loop selection',294,300,133,34,function()
   S.manual()
   local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false);if e<=s then error('Drag a time selection in the timeline first.',0) end
   R.GetSet_LoopTimeRange2(0,true,true,s,e,false);R.GetSetRepeat(1);R.SetEditCurPos2(0,s,true,false)
  end)
  button('Click '..(R.GetToggleCommandStateEx(0,40364)==1 and 'on' or 'off'),435,300,90,34,function()R.Main_OnCommand(40364,0) end)
  button('Count-in...',533,300,106,34,function()R.Main_OnCommand(40363,0) end)
  local punch=R.GetToggleCommandStateEx(0,40076)==1
  button(punch and 'Punch on' or 'Punch off',647,300,w-671,34,function()S.manual();R.Main_OnCommand(punch and 40252 or 40076,0) end)
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  text(e>s and ('Selected: '..R.format_timestr_pos(s,'',2)..' to '..R.format_timestr_pos(e,'',2)) or 'Select a passage in the timeline to compare or comp.',25,346,3,C.muted,w-220)
  button('Clear selection',w-174,339,150,28,function()
   S.manual();R.Main_OnCommand(40020,0);status='Time selection and loop range cleared.'
  end,nil,not recording)
  local selected_count=#selected_rows();local single=not recording and selected_count==1
  text((S.mode()=='section' and 'Section takes' or 'Takes')..(selected_count>1 and (' / '..selected_count..' selected')or ''),24,381,4)
  button('Audition',w-322,371,94,34,function()take_action('audition')end,C.blue,single)
  button('Previous',w-220,371,92,34,function()select_step(-1) end)
  button('Next',w-120,371,96,34,function()select_step(1) end)
  local table_y=419; local table_end=gfx.h-180;local visible=math.max(1,math.floor((table_end-table_y)/42))
  local focus=chosen()
  if focus and focus.key~=review_focus then
   for i,row in ipairs(rows)do if row.key==focus.key then
    if i<=scroll then scroll=i-1 elseif i>scroll+visible then scroll=i-visible end
   end end
  end
  review_focus=focus and focus.key
  scroll=math.max(0,math.min(scroll,#rows-visible))
  if #rows==0 then
   text(#tracks==0 and 'Add an instrument to begin.' or 'Your recorded takes will appear here.',30,439,1,C.muted)
   text('Use one recording set for a single instrument or all microphones of a kit.',30,467,3,C.muted)
  else
   for i=scroll+1,math.min(#rows,scroll+visible) do
    local row=rows[i];local y=table_y+(i-scroll-1)*42
    color(selection.has(row.key) and {0.25,0.35,0.43} or C.surface);gfx.rect(24,y,w-48,38,1)
    if row.playing then color(C.blue);gfx.rect(24,y,4,38,1) end
    local name=row.name:match('^%d+$') and 'Take '..row.name or row.name
    text(name,39,y+10,1,C.text,175)
    text(row.favorite and 'Favorite' or '',220,y+11,3,C.gold)
    text(row.note~='' and row.note or 'Select, then Audition to hear this take',315,y+11,3,row.note~='' and C.text or C.muted,w-350)
    if not recording then buttons[#buttons+1]={x=24,y=y,w=w-48,h=38,fn=function()select_take(row)end}end
   end
  end
  local fy=gfx.h-167
  button('Favorite',24,fy,100,35,function()take_action('favorite')end,nil,single)
  button('Take note',132,fy,110,35,function()annotate(false) end,nil,single)
  button('Passage note',250,fy,128,35,function()annotate(true) end,nil,single)
  button('Rename',386,fy,89,35,rename,nil,single)
  button(selected_count>1 and ('Delete '..selected_count..' takes')or 'Delete take',483,fy,160,35,function()take_action('delete')end,C.record,not recording and selected_count>0)
  button('Keep passage',w-207,fy,183,35,function()take_action('comp')end,C.blue,single)
  local cr=chosen();local sn=cr and e>s and M.section_note(cr.lane,s,e) or ''
  text(sn~='' and ('Passage note: '..sn) or 'Cmd-click: toggle takes / Shift-click: range. Delete removes whole passes; Cmd+Z in REAPER restores them.',25,fy+46,3,C.muted,w-50)
  section_sidebar(w+12,264,recording)
  end
  color(C.line);gfx.line(24,gfx.h-78,gfx.w-24,gfx.h-78)
  text(status,25,gfx.h-64,3,C.text,gfx.w-50)
  text('Space: play/stop   R: record   N: another take   Left/Right: takes   F: favorite   B: transition   M: mix',25,gfx.h-36,3,C.muted,w-50)
 end
 local down=gfx.mouse_cap&1==1
 local consumed=view=='timeline' and V.mouse(down,down and not mouse_down,R.GetPlayState()&4~=0)
 if down and not mouse_down and not consumed then
  for _,s in ipairs(sliders) do
   if gfx.mouse_x>=s.x-6 and gfx.mouse_x<s.x+s.w+6 and gfx.mouse_y>=s.y and gfx.mouse_y<s.y+s.h then
    drag=s;drag.project=R.EnumProjects(-1,'');break
   end
  end
  if not drag then for _,b in ipairs(buttons) do if gfx.mouse_x>=b.x and gfx.mouse_x<b.x+b.w and gfx.mouse_y>=b.y and gfx.mouse_y<b.y+b.h then run(b.fn);break end end end
 end
 if drag then
  local available=false;for _,s in ipairs(sliders) do if s.id==drag.id then available=true end end
  if drag.project~=R.EnumProjects(-1,'') or not available then drag=nil
  else
   drag.value=math.max(0,math.min(1,(gfx.mouse_x-drag.x)/drag.w))
   if not down then local finished=drag;drag=nil;run(function()finished.fn(finished.value) end) end
  end
 end
 mouse_down=down
 if gfx.mouse_wheel~=0 then
  local delta=gfx.mouse_wheel>0 and 1 or -1
  if view=='timeline' then V.wheel(delta)
  elseif view=='mix' then mix().wheel(delta)
  elseif gfx.mouse_x>gfx.w-300 then section_scroll=section_scroll-delta else scroll=scroll-delta end
  gfx.mouse_wheel=0
 end
 local ch=gfx.getchar()
 if ch==27 and V.cancel()then ch=0 end
 if view=='mix' and X and X.key(ch)then ch=0 end
 if ch==109 or ch==77 then run(function()change_view('mix')end)
 elseif ch==32 then run(play) elseif ch==114 or ch==82 then run(M.record)
 elseif ch==110 or ch==78 then run(M.another)
 elseif ch==1818584692 then run(function()select_step(-1) end)
 elseif ch==1919379572 then run(function()select_step(1) end)
 elseif ch==102 or ch==70 then run(function()with_row(function(row)M.favorite(row.lane) end) end)
 elseif ch==98 or ch==66 then run(mark_transition)
 end
 gfx.update();if ch>=0 and ch~=27 then R.defer(frame) end
end
frame()
