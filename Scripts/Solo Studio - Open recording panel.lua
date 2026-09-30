local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(dir..'/solo_core.lua')
local T=dofile(dir..'/solo_tempo.lua')
local S=M.sections()
local R=reaper
local C={bg={0.16,0.18,0.21},header={0.21,0.28,0.34},content={0.11,0.13,0.16},surface={0.21,0.24,0.28},line={0.32,0.36,0.40},text={0.93,0.94,0.95},muted={0.67,0.72,0.77},blue={0.35,0.58,0.76},record={0.73,0.34,0.39},gold={0.91,0.72,0.35}}
local selection=dofile(dir..'/solo_take_selection.lua')()
local mouse_down,scroll=false,0
local review_focus
local status='Drag in the song timeline to add a section, or use New section... for an exact start and length.'
local lastproject,rows,tracks,lastrefresh=nil,{},{},0
local all_rows,lastset,was_recording={},nil,false
local buttons={}
local sliders,drag={},nil
local header_hint
local title_source,song_identity
local track_settings
local template_settings
local set_tab_first,set_tab_active,set_tab_layout=1,nil,nil
local set_tab_strip
local section_scroll,sections=0,{}
local saved_view=R.GetExtState(M.ns,'panel_view')
local view=(saved_view=='review' or saved_view=='mix' or saved_view=='tracks' or saved_view=='projects') and saved_view or 'timeline'
local V,X,K,P
local change_view
local listen_mode='comp'
local comp_row,clip_target
local take_action
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
local function refresh_takes()
 all_rows={};comp_row=nil
 for _,row in ipairs(M.lanes())do
  if row.is_comp then comp_row=row elseif not row.is_preview then all_rows[#all_rows+1]=row end
 end
 rows=S.filter_takes(all_rows)
 if comp_row and comp_row.playing then listen_mode='comp'
 else
  for _,row in ipairs(all_rows)do if row.playing then listen_mode='take';return end end
  if not comp_row then listen_mode='take'end
 end
end
local function tempo_menu()
 M.stopped();M.finish_recorded_tempo();refresh_takes()
 local selected=selected_rows()
 local choice=gfx.showmenu('Select takes with different tempo|Select takes with unknown tempo|'..(#selected==0 and '#'or '')..'Set recorded BPM for selected takes...')
 if choice==1 or choice==2 then
  local matching={}
  for _,row in ipairs(candidates())do
   local t=row.tempo or {unknown=true}
   if choice==1 and t.different or choice==2 and t.unknown and not t.mixed then matching[#matching+1]=row end
  end
  selection.replace(matching);clip_target=nil
  status=#matching..' takes selected '..(choice==1 and 'with a different recorded tempo' or 'without a known recorded tempo')..'. Review the selection, then Delete takes.'
  if choice==1 and #matching==0 then status='No known tempo mismatches here. Unknown, mixed, and tempo-map takes are not selected.'end
 elseif choice==3 then
  assert(#selected>0,'Select at least one take.')
  local bpm=#selected==1 and selected[1].tempo and selected[1].tempo.bpm
  local ok,value=R.GetUserInputs('Label '..#selected..' selected take(s)',1,'Known recording BPM (label only):,extrawidth=200',bpm and tostring(bpm)or '')
  if ok then M.recorded_tempo().assign(selected,tonumber(value));refresh_takes();status='Recorded tempo labels saved. Audio and the song tempo are unchanged.'end
 end
end
local function target_range(row)
 if clip_target and clip_target.key==row.key then return clip_target.s,clip_target.e end
 local section=S.mode()=='section' and S.active()
 if section then return section.s,section.e end
 local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
 if e>s then return s,e end
 s,e=math.huge,0
 for _,it in ipairs(row.items)do if R.ValidatePtr2(0,it,'MediaItem*')then local a=R.GetMediaItemInfo_Value(it,'D_POSITION');s=math.min(s,a);e=math.max(e,a+R.GetMediaItemInfo_Value(it,'D_LENGTH'))end end
 return s,e
end
local function select_take(row,clip,position)
 selection.click(candidates(),row.key,gfx.mouse_cap&4~=0,gfx.mouse_cap&8~=0)
 if gfx.mouse_cap&12==0 then
  clip_target=nil
  if clip then
   local s,e=clip.s,clip.e
   for _,region in ipairs(S.list())do if position>=region.s and position<region.e then s=math.max(s,region.s);e=math.min(e,region.e);break end end
   clip_target={key=row.key,s=s,e=e}
  end
 end
 local count=#selected_rows()
 status=count==1 and ('Selected '..chosen().name..'. Use in comp keeps the selected passage.')
  or count..' takes selected. Cmd-click toggles a take; Shift-click selects a range.'
 if listen_mode=='take'and count==1 then run(function()take_action('listen_take')end)end
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
local function track_view()
 if not K then K=dofile(dir..'/solo_tracks_view.lua')(M,{colors=C,text=text,button=button,color=color,
  hit=function(x,y,w,h,fn,enabled)if enabled then buttons[#buttons+1]={x=x,y=y,w=w,h=h,fn=fn}end end,
  changed=function(message)status=message;lastrefresh=0;selection.reset();clip_target=nil end})end
 return K
end
local function project_view()
 if not P then P=dofile(dir..'/solo_projects_view.lua')(M,{colors=C,text=text,button=button,color=color,run=run,
  hit=function(x,y,w,h,fn,enabled)if enabled then buttons[#buttons+1]={x=x,y=y,w=w,h=h,fn=fn}end end,
  opened=function(message)status=message;lastrefresh=0;change_view('timeline')end},
  {busy=function()return X and X.busy()end,before_switch=function()if X then X.close();X=nil end end})end
 return P
end
local function history(redo)
 M.stopped()
 assert(not X or not X.busy(),'Wait for the current mix operation before using Undo or Redo.')
 if V.cancel_drag()or drag then drag=nil;status='Pending edit cancelled.';return end
 local label=M.history(redo)
 if label then
  clip_target=nil;tracks=M.tracks();refresh_takes();sections=S.list();selection.sync(candidates())
  V.history_changed();lastrefresh=0
  status=(redo and 'Redid: 'or'Undid: ')..label:gsub('^Solo Studio: ','')
 end
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
local function set_tempo(value)
 assert(not X or not X.busy(),'Wait for the current AI mix operation before changing tempo.')
 T.set_bpm(value);status='Song tempo updated.'
end
local function tempo_input()
 local ok,s=R.GetUserInputs('Song tempo',1,'Tempo (20-300 BPM):',string.format('%.2f',T.bpm()))
 if ok then set_tempo(tonumber(s))end
end
local function click_input()
 local db=T.click_db()
 local ok,s=R.GetUserInputs('Click volume',1,'Volume (-60 to 0 dB):',string.format('%.1f',db and db>-60 and math.min(0,db) or -12))
 if ok then T.set_click_db(tonumber(s));status='Click volume updated.' end
end
local function current_song_title()
 local project,path=R.EnumProjects(-1,'');local now=R.time_precise()
 if not song_identity or song_identity.project~=project or song_identity.path~=path or now-song_identity.at>1 then
  -- Share the bounce library's title lookup, including project-library renames
  -- and restored mix snapshots, without scanning or changing the song catalog.
  title_source=title_source or dofile(dir..'/solo_bounces.lua')
  local ok,identity=pcall(title_source.identity)
  local title=ok and identity.title or (path or ''):match('([^/\\]+)%.[Rr][Pp][Pp]$')or 'Untitled song'
  song_identity={project=project,path=path,at=now,title=title:gsub('%c',' ')}
 end
 return song_identity.title
end
local function draw_song_title(right)
 local title=current_song_title();local label=title;local width=right-248
 gfx.setfont(4)
 if gfx.measurestr(label)>width then
  repeat
   label=label:sub(1,(utf8.offset(label,-1)or #label)-1)
  until label==''or gfx.measurestr(label..'…')<=width
  label=label..'…'
 end
 color(C.line);gfx.line(205,25,205,52)
 text(label,224,29,4,C.text,width)
 if gfx.mouse_x>=224 and gfx.mouse_x<right-24 and gfx.mouse_y>=20 and gfx.mouse_y<56 then
  header_hint='Current song: '..title
 end
end
-- Shared song controls are drawn before every view, including Projects and Mix.
local function song_header(recording)
 local extra=gfx.w-1200;local offset=extra*.45
 local tempo_enabled=T.tempo_enabled()and (not X or not X.busy())
 local bpm=drag and drag.id=='tempo'and math.floor(T.min_bpm+drag.value*(T.max_bpm-T.min_bpm)+0.5)or T.bpm()
 text('Tempo',24,77,3,C.muted)
 button(string.format(bpm%1==0 and '%.0f BPM'or '%.2f BPM',bpm),104,72,117,24,tempo_input,nil,tempo_enabled)
 slider('tempo',234,73,202+offset,(T.bpm()-T.min_bpm)/(T.max_bpm-T.min_bpm),function(value)
  set_tempo(math.floor(T.min_bpm+value*(T.max_bpm-T.min_bpm)+0.5))
 end,tempo_enabled)
 local db=drag and drag.id=='volume'and T.position_db(drag.value)or T.click_db()
 text('Click volume',458+offset,77,3,C.muted)
 button(T.format_db(db),551+offset,72,99,24,click_input,nil,T.click_db()~=nil)
 slider('volume',663+offset,73,182+extra*.55,T.volume_position(),function(value)
  T.set_volume(value);status='Click volume: '..T.format_db(T.click_db())
 end,T.click_db()~=nil)
 local click_on=R.GetToggleCommandStateEx(0,40364)==1
 button(click_on and 'Click on'or 'Click off',gfx.w-334,72,100,24,function()R.Main_OnCommand(40364,0)end,click_on and C.blue or nil)
 button('Click sound...',gfx.w-222,72,114,24,function()
  T.sound_settings();status='Click sound: choose a waveform, pitch, or custom sample in REAPER.'
 end)
 button('Tuner',gfx.w-100,72,76,24,function()dofile(dir..'/solo_tuner.lua').open()end)
 if gfx.mouse_y>=72 and gfx.mouse_y<97 then
  if gfx.mouse_x>=24 and gfx.mouse_x<444+offset then
   header_hint=tempo_enabled and 'Song tempo: drag for 20–300 BPM, or click the value to enter an exact tempo.'
    or recording and 'Tempo is locked while recording.'
    or X and X.busy()and 'Tempo is locked during the AI mix operation.'
    or 'This song has a tempo map. Edit its tempo markers in REAPER.'
  elseif gfx.mouse_x>=458+offset and gfx.mouse_x<853+extra then
   header_hint='Click volume: drag from mute to 0 dB, or click the value to enter a level. Applies to the current song.'
  end
 end
end
local function template_guard(expected_tracks)
 assert(template_settings and template_settings.project==R.EnumProjects(-1,''),'The project changed. Reopen Create new template.')
 assert(not (X and X.busy()),'Finish the current AI mix operation before creating a template.')
 M.stopped()
 if expected_tracks then
  local current=M.selected();assert(#current==#expected_tracks,'The selected tracks changed. Select them again before creating the template.')
  for i,tr in ipairs(current)do assert(tr==expected_tracks[i],'The selected tracks changed. Select them again before creating the template.')end
 end
end
local function name_set()
 template_guard()
 local t=M.selected();if #t==0 then error('Select a track or the microphone tracks for one instrument in REAPER first.',0) end
 local ok,name=R.GetUserInputs('Name this recording set',1,'Instrument or performance:,extrawidth=180',#t==1 and M.track_name(t[1]) or 'Drums')
 if ok and name~='' then
  template_guard(t);M.capture(name);selection.reset();template_settings=nil
  status='Recording set saved. Its microphone lanes must represent matching passes.'
 end
end
local function add_instrument(x,y)
 gfx.x=x;gfx.y=y
 local n=gfx.showmenu('Vocals|Guitar|Bass|Drums (several microphones)||Create new template...')
 if n==5 then
  drag=nil;V.cancel();track_settings=nil
  template_settings={project=R.EnumProjects(-1,'')};return
 end
 local kinds={'Vocals','Guitar','Bass','Drums'};local kind=kinds[n];if not kind then return end
 local names
 if kind=='Drums' then
  local ok,s=R.GetUserInputs('Drum microphone tracks',1,'Names separated by semicolons:,extrawidth=280','Kick;Snare;Overhead L;Overhead R')
  if not ok then return end
  names={};for name in s:gmatch('[^;]+') do name=name:match('^%s*(.-)%s*$');if name~='' then names[#names+1]=name end end
  if #names==0 or #names>32 then error('Enter between 1 and 32 microphone names.',0) end
 end
 M.add_instrument(kind,names);selection.reset();status=kind..' added. Choose Track settings > Assign inputs before recording.'
end
local function recording_set_tabs(end_x,y,active,recording)
 local sets=M.sets();local widths,total,active_index={},0,nil
 local signature={tostring(end_x)}
 gfx.setfont(1)
 for i,set in ipairs(sets)do
  widths[i]=math.min(210,math.max(85,gfx.measurestr(set.name)+24))
  total=total+widths[i]+(i>1 and 7 or 0)
  signature[#signature+1]=set.id..':'..set.name
  if set.id==active then active_index=i end
 end
 local layout=table.concat(signature,'\n')
 local overflow=total>end_x-24
 gfx.setfont(3)
 local badge_width=math.max(19,gfx.measurestr(tostring(#sets))+8)
 local arrow_width=badge_width+30
 local left,right=overflow and 24+arrow_width+7 or 24,overflow and end_x-arrow_width-7 or end_x
 local available=right-left
 local function last_visible(first)
  local used,last=0,first-1
  for i=first,#sets do
   local next_width=widths[i]+(i>first and 7 or 0)
   if used+next_width>available then break end
   used=used+next_width;last=i
  end
  return last
 end
 local last_start,used=#sets,0
 for i=#sets,1,-1 do
  local next_width=widths[i]+(i<#sets and 7 or 0)
  if used+next_width>available then break end
  used=used+next_width;last_start=i
 end
 last_start=math.max(1,last_start)
 set_tab_first=overflow and math.max(1,math.min(set_tab_first,last_start))or 1
 if active_index and (active~=set_tab_active or layout~=set_tab_layout)then
  if active_index<set_tab_first then set_tab_first=active_index end
  while active_index>last_visible(set_tab_first)and set_tab_first<last_start do set_tab_first=set_tab_first+1 end
 end
 set_tab_active=active;set_tab_layout=layout
 local function move(delta)set_tab_first=math.max(1,math.min(last_start,set_tab_first+delta))end
 set_tab_strip={x=24,y=y,w=end_x-24,h=33,move=move}
 local last=last_visible(set_tab_first)
 if overflow then
  local function arrow(label,x,count,direction)
   button('',x,y,arrow_width,33,function()move(direction)end,nil,count>0)
   text(label,x+8,y+8,1,count>0 and C.text or C.muted)
   color(count>0 and C.blue or C.line);gfx.rect(x+25,y+7,badge_width,19,1)
   gfx.setfont(3);local tw,th=gfx.measurestr(tostring(count))
   text(tostring(count),x+25+(badge_width-tw)/2,y+7+(19-th)/2,3,count>0 and C.text or C.muted)
   if gfx.mouse_x>=x and gfx.mouse_x<x+arrow_width and gfx.mouse_y>=y and gfx.mouse_y<y+33 then
    header_hint=count..(count==1 and ' recording set hidden to the 'or ' recording sets hidden to the ')..(direction<0 and 'left.'or 'right.')
   end
  end
  arrow('<',24,set_tab_first-1,-1)
  arrow('>',end_x-arrow_width,#sets-last,1)
 end
 local x=left
 for i=set_tab_first,last do
  local set=sets[i];local sw=widths[i]
  button(set.name,x,y,sw,33,function()
   M.choose_set(set.id);selection.reset();scroll=0
  end,set.id==active and C.blue or nil,not recording)
  if gfx.mouse_x>=x and gfx.mouse_x<x+sw and gfx.mouse_y>=y and gfx.mouse_y<y+33 then
   header_hint=set.name..(overflow and ' — scroll this row or use its arrows for more recording sets.'or ' — click to select this recording set.')
  end
  x=x+sw+7
 end
end
local function settings_guard(expected_tracks)
 assert(track_settings and track_settings.project==R.EnumProjects(-1,'')and track_settings.set==M.get('active'),'The recording set changed. Reopen Track settings.')
 assert(not (X and X.busy()),'Finish the current AI mix operation before changing track settings.')
 M.stopped()
 if expected_tracks then
  local current=M.require_tracks();assert(#current==#expected_tracks,'The recording tracks changed. Reopen Track settings.')
  for i,tr in ipairs(current)do assert(tr==expected_tracks[i],'The recording tracks changed. Reopen Track settings.')end
 end
end
local function inputs()
 settings_guard()
 local ts=M.require_tracks();local n=R.GetNumAudioInputs()
 if n==0 then error('REAPER has no audio inputs. Connect your interface and choose it in REAPER > Settings > Audio > Device.',0) end
 local lines={'Available mono inputs:'};for i=0,n-1 do lines[#lines+1]=(i+1)..': '..R.GetInputChannelName(i) end
 local labels,defaults={},{}
 for _,tr in ipairs(ts) do labels[#labels+1]=M.track_name(tr);defaults[#defaults+1]=tostring(math.max(1,R.GetMediaTrackInfo_Value(tr,'I_RECINPUT')+1)) end
 M.message(table.concat(lines,'\n')..'\n\nNext, enter input numbers in this order:\n'..table.concat(labels,'; '))
 local ok,s=R.GetUserInputs('Assign inputs: '..table.concat(labels,' / '),1,'Input numbers separated by semicolons:,extrawidth=260',table.concat(defaults,';'))
 if ok then
  settings_guard(ts)
  local values={};for v in s:gmatch('[^;]+') do values[#values+1]=tonumber(v) or -1 end
  M.inputs(values);status='Inputs assigned. Record will arm this set automatically.'
  track_settings.message=status
 end
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
take_action=function(action)
 if action=='listen_comp' then
  M.listen_comp();listen_mode='comp';refresh_takes()
  status='Comp selected for playback. Click takes freely, or switch to Take to hear the highlighted take.'
  return
 end
 if action=='listen_take' then
  with_row(function(row)
   local live=assert(M.row_for_key(row.key),'This take changed. Select it again.')
   M.audition(live.lane,true);listen_mode='take';refresh_takes()
   status='Listening to '..live.name..'. Selecting another take switches playback; Use in comp keeps the selected passage.'
  end)
  return
 end
 if action=='delete' then
  local selected=selected_rows();assert(#selected>0,'Select at least one take to delete.')
  local before={};for i,row in ipairs(candidates())do before[i]=row end
  local next_key=listen_mode=='take'and selection.neighbor_after_delete(before,selected)or nil
  M.delete_takes(selected,next_key)
  selection.after_delete(before,selected)
  refresh_takes();selection.sync(candidates())
  status='Deleted '..#selected..(#selected==1 and ' take' or ' takes')..' across the recording set. Audio files kept. Cmd+Z in REAPER restores them.'
  return
 end
 if action=='note' then annotate(false);return end
 if action=='rename' then rename();return end
 with_row(function(row)
  if action=='favorite' then M.favorite(row.lane)
  elseif action=='comp' then
   local s,e=target_range(row);M.use_in_comp(row.key,s,e);listen_mode='comp';refresh_takes();status='This passage is active in the comp. Switch to Take to compare another performance.'
  end
 end)
end
local function play()
 if R.GetPlayState()~=0 then M.stop() else R.OnPlayButton() end
end
local function select_step(d)
 M.stopped()
 local list=candidates();local row=chosen();assert(#list>0,'Record or import a take first.')
 local index=1;for i,candidate in ipairs(list)do if row and candidate.key==row.key then index=i end end
 local next_row=list[((index-1+d)%#list)+1]
 selection.only(next_row.key)
 if clip_target then clip_target={key=next_row.key,s=clip_target.s,e=clip_target.e}end
 if listen_mode=='take'then take_action('listen_take')end
end
local function monitoring()
 settings_guard()
 local ts=M.require_tracks();local on=true
 for _,tr in ipairs(ts)do if R.GetMediaTrackInfo_Value(tr,'I_RECMON')>0 then on=false end end
 M.edit('input monitoring',function()for _,tr in ipairs(ts) do R.SetMediaTrackInfo_Value(tr,'I_RECMON',on and 1 or 0) end end)
 status=on and 'Software monitoring on. Use headphones while recording microphones.' or 'Software monitoring off. Use interface monitoring if needed.'
 track_settings.message=status
end
local function show_track_settings()
 drag=nil;V.cancel();template_settings=nil
 track_settings={project=R.EnumProjects(-1,''),set=M.get('active')}
end
local function draw_track_settings()
 local w,h=650,390;local x,y=(gfx.w-w)/2,math.max(16,(gfx.h-h)/2)
 gfx.set(0,0,0,.58);gfx.rect(0,0,gfx.w,gfx.h,1)
 color(C.line);gfx.rect(x-1,y-1,w+2,h+2,1);color(C.bg);gfx.rect(x,y,w,h,1)
 text('Track settings',x+24,y+20,2)
 button('Done',x+w-114,y+22,90,32,function()track_settings=nil end)
 local ts=M.tracks();local count=#ts;local armed,monitored=0,0
 for _,tr in ipairs(ts)do
  if R.GetMediaTrackInfo_Value(tr,'I_RECARM')~=0 then armed=armed+1 end
  if R.GetMediaTrackInfo_Value(tr,'I_RECMON')>0 then monitored=monitored+1 end
 end
 text((M.get('set.'..M.get('active')..'.name')or 'Recording set')..'  ·  '..count..(count==1 and ' track'or ' tracks'),x+24,y+64,3,C.muted,w-48)
 local recording=R.GetPlayState()&4~=0;local busy=X and X.busy()
 local enabled=count>0 and not recording and not busy
 local function row(title,description,offset,label,fn)
  color(C.line);gfx.line(x+24,y+offset-12,x+w-24,y+offset-12)
  text(title,x+24,y+offset,4)
  text(description,x+24,y+offset+28,3,C.muted,w-245)
  button(label,x+w-190,y+offset+5,166,36,fn,nil,enabled)
 end
 row('Audio inputs','Assign an interface input to each track.',112,'Assign inputs...',inputs)
 row('Recording',armed..' of '..count..' armed. Record arms this set automatically.',190,'Arm set',function()
  settings_guard();M.arm();status='Only this recording set is armed.';track_settings.message=status
 end)
 local description=monitored==0 and 'Off. Listen through your interface.'or monitored==count and 'On. Listen to the input through REAPER.'or 'Mixed: some tracks have monitoring on.'
 row('Input monitoring',description,268,monitored>0 and 'Turn off'or 'Turn on',monitoring)
 local message=recording and 'Finish recording to change these settings.'or busy and 'Finish the AI mix operation to change these settings.'or track_settings.message or 'Changes apply immediately. Press Esc to close.'
 text(message,x+24,y+h-35,3,C.muted,w-48)
end
local function draw_template_settings()
 local w,h=650,460;local x,y=(gfx.w-w)/2,math.max(16,(gfx.h-h)/2)
 gfx.set(0,0,0,.58);gfx.rect(0,0,gfx.w,gfx.h,1)
 color(C.line);gfx.rect(x-1,y-1,w+2,h+2,1);color(C.bg);gfx.rect(x,y,w,h,1)
 text('Create new template',x+24,y+20,2)
 button('Cancel',x+w-114,y+22,90,32,function()template_settings=nil end)
 text('Use existing tracks as one recording set in this song.',x+24,y+66,3,C.muted)
 text('Select the tracks in REAPER, then return here.',x+24,y+107,4)
 text('For drums, select all microphone tracks, leaving the folder unselected.',x+24,y+137,3,C.muted)
 local selected=M.selected();local count=#selected
 color(C.line);gfx.line(x+24,y+174,x+w-24,y+174)
 text(count..(count==1 and ' selected track'or ' selected tracks'),x+24,y+188,4)
 if count==0 then text('No tracks selected yet.',x+24,y+224,1,C.muted)
 else
  for i=1,math.min(count,6)do text(M.track_name(selected[i]),x+24,y+222+(i-1)*22,1,C.text,w-48)end
  if count>6 then text('and '..(count-6)..' more',x+24,y+355,3,C.muted)end
 end
 local recording=R.GetPlayState()&4~=0;local busy=X and X.busy()
 local hint=recording and 'Finish recording to create a template.'or busy and 'Finish the AI mix operation to create a template.'or 'Next, give this recording set a name.'
 text(hint,x+24,y+h-66,3,C.muted,w-48)
 button('Use selected tracks',x+w-218,y+h-48,194,32,name_set,C.blue,count>0 and not recording and not busy)
end
local function mark_transition()
 local row=S.split();status='Transition marked. Rename '..row.name..' when you are ready.'
end
change_view=function(value)
 if value~=view then clip_target=nil end
 view=value;if value=='projects'then if P then P.reset()end;status='Choose a song, or start a full-band song in Desktop/Solo Studio Songs.'end;selection.sync(candidates());drag=nil;V.cancel();R.SetExtState(M.ns,'panel_view',value,true)
end
local function section_sidebar(x,w,recording)
 button('Edit song timeline',x,223,w,36,function()change_view('timeline')end,C.blue)
 local list_y=297;local visible=math.max(1,math.floor((gfx.h-120-list_y)/48))
 section_scroll=math.max(0,math.min(section_scroll,#sections-visible))
 text('Song sections',x,271,4)
 local active=S.active()
 if #sections==0 then
  text('Open Song timeline to draw',x,323,1,C.muted)
  text('a section or enter its length.',x,349,1,C.muted)
 else for i=section_scroll+1,math.min(#sections,section_scroll+visible)do
  local row=sections[i];local y=list_y+(i-section_scroll-1)*48
  color(active and active.key==row.key and {0.25,0.35,0.43}or C.surface);gfx.rect(x,y,w,43,1)
  text(row.name,x+10,y+5,1,C.text,w-20)
  text(R.format_timestr_pos(row.s,'',2)..' - '..R.format_timestr_pos(row.e,'',2),x+10,y+26,3,C.muted,w-20)
  if not recording then buttons[#buttons+1]={x=x,y=y,w=w,h=43,fn=function()clip_target=nil;S.select(row.key);selection.reset();scroll=0;status='Ready for '..row.name..'.'end}end
 end end
 text('Click a section to record or comp it.',x,gfx.h-94,3,C.muted)
end
V=dofile(dir..'/solo_timeline.lua')(M,S,{colors=C,text=text,button=button,color=color,run=run,
 changed=function(message)clip_target=nil;status=message;lastrefresh=0;selection.reset();scroll=0 end,
 rows=function()return all_rows end,chosen=chosen,take_action=take_action,tempo_menu=tempo_menu,
 comp=function()return comp_row end,listen_mode=function()return listen_mode end,
 comp_edges=function()return M.comp_edges().list()end,
 comp_edge_plan=function(key,pos,signature)return M.comp_edges().plan(key,pos,signature)end,
 move_comp_edge=function(key,pos,signature)M.comp_edges().move(key,pos,signature)end,
 target=function()local row=chosen();if row and #selected_rows()==1 then local s,e=target_range(row);if e>s then return {s=s,e=e}end end end,
 selected=selection.has,selection_count=function()return #selected_rows()end,select=select_take})
local function refresh()
 local proj=R.EnumProjects(-1,'')
 if track_settings and (track_settings.project~=proj or track_settings.set~=M.get('active'))then track_settings=nil end
 if template_settings and template_settings.project~=proj then template_settings=nil end
 if proj~=lastproject then if X then X.close();X=nil end;if P then P.reset()end;M.cancel_preview(proj);listen_mode='comp';clip_target=nil;S.recover_leadin();selection.reset();scroll=0;section_scroll=0;set_tab_first=1;set_tab_active=nil;set_tab_layout=nil;drag=nil;V.reset();if K then K.reset()end;review_focus=nil;lastset=nil;was_recording=false;lastproject=proj;lastrefresh=0 end
 local recording=R.GetPlayState()&4~=0
 if R.time_precise()-lastrefresh>0.25 or recording~=was_recording then
  local set=M.get('active');local previous={}
  if not recording then M.finish_recorded_tempo()end
  if set~=lastset then listen_mode='comp';clip_target=nil;selection.reset();review_focus=nil end
  if set==lastset then for _,row in ipairs(all_rows)do previous[row.key]=true end end
  tracks=M.tracks();refresh_takes();sections=S.list()
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
local function open_window(w,h,dock,x,y)
 if x and y then gfx.init('Solo Studio | Record & review',w,h,dock,x,y)
 else gfx.init('Solo Studio | Record & review',w,h,dock)end
 gfx.setfont(1,'Helvetica',16);gfx.setfont(2,'Helvetica',28,98);gfx.setfont(3,'Helvetica',13);gfx.setfont(4,'Helvetica',19,98)
end
open_window(1200,754,tonumber(R.GetExtState(M.ns,'dock')) or 0)
R.SetExtState(M.ns,'panel_open','1',false);R.SetExtState(M.ns,'panel_raise','',false)
R.atexit(function()R.SetExtState(M.ns,'panel_open','',false);if X then X.close() end;R.SetExtState(M.ns,'dock',tostring(gfx.dock(-1)),true) end)
local function frame()
 if R.GetExtState(M.ns,'panel_raise')=='1'then
  R.SetExtState(M.ns,'panel_raise','',false)
  local dock,x,y,w,h=gfx.dock(-1)
  -- Recreate only the native window to unminimize/raise it. The Lua panel,
  -- selection, and any active mix worker stay alive without running cleanup.
  gfx.quit();open_window(w or 1200,h or 754,dock,x,y)
 end
 refresh();if X then X.poll() end;buttons={};sliders={};header_hint=nil;set_tab_strip=nil;color(C.bg);gfx.rect(0,0,gfx.w,gfx.h,1)
 local min_height=view=='timeline'and 688 or view=='mix'and 708 or view=='projects'and 674 or 661
 if gfx.w<1180 or gfx.h<min_height then
  V.reset()
  text('Make this panel at least 1180 x '..min_height..' to show this workspace.',20,25,1)
 else
  local w=gfx.w-300;local active=M.get('active');local recording=R.GetPlayState() & 4 ~= 0
  color(C.header);gfx.rect(0,0,gfx.w,64,1)
  local content_y=view=='projects'and 104 or 217
  color(C.content);gfx.rect(0,content_y,gfx.w,gfx.h-content_y,1)
  text('Solo Studio',24,20,2)
  local actions_x=gfx.w-433
  draw_song_title(actions_x)
  local undo_label,redo_label=R.Undo_CanUndo2(0),R.Undo_CanRedo2(0)
  local history_enabled=not recording and (not X or not X.busy())
  button('Undo',actions_x,24,76,32,function()history(false)end,nil,history_enabled and (undo_label or '')~='')
  button('Redo',actions_x+84,24,76,32,function()history(true)end,nil,history_enabled and (redo_label or '')~='')
  if gfx.mouse_y>=24 and gfx.mouse_y<56 and gfx.mouse_x>=actions_x and gfx.mouse_x<actions_x+160 then
   local redo=gfx.mouse_x>=actions_x+84;local label=undo_label;if redo then label=redo_label end
   header_hint=label and label~=''and ((redo and 'Redo: 'or 'Undo: ')..label:gsub('^Solo Studio: ',''))or 'No earlier edits'
  end
  button('Projects',gfx.w-257,24,110,32,function()change_view(view=='projects'and 'timeline'or 'projects')end,view=='projects'and C.blue or nil)
  button('Save project',gfx.w-139,24,115,32,function()R.Main_OnCommand(40026,0) end)
  song_header(recording)
  color(C.line);gfx.line(24,64,gfx.w-24,64);gfx.line(24,104,gfx.w-24,104)
  if view=='projects'then
   project_view().draw(24,120,gfx.w-48,gfx.h-206)
  else
  recording_set_tabs(gfx.w-350,112,active,recording)
  color(C.line);gfx.line(gfx.w-343,112,gfx.w-343,145)
  button('Track settings...',gfx.w-336,112,160,33,show_track_settings,nil,#tracks>0)
  button('+ Instrument',gfx.w-164,112,140,33,function()add_instrument(gfx.w-164,145)end)
  color(C.line);gfx.line(24,152,gfx.w-24,152)
  local record_label=S.mode()=='section' and 'Record section' or (S.mode()=='full' and 'Record full song' or 'Record')
  button(recording and 'Stop & keep' or record_label,24,160,160,49,function()M.record() end,C.record)
  button(R.GetPlayState()~=0 and 'Stop' or 'Play',195,160,115,49,play)
  button('Full song',326,168,104,33,function()S.full_song();status='Ready to record the whole song. Stop & keep when finished.'end,S.mode()=='full' and C.blue or nil,not recording)
  button('One pass',446,168,102,33,function()S.set_loop(false)end,not S.looping() and C.blue or nil,not recording)
  button('Loop takes',555,168,114,33,function()S.set_loop(true)end,S.looping() and C.blue or nil,not recording)
  text(S.label(),689,178,3,C.muted,gfx.w-1097)
  if gfx.mouse_x>=24 and gfx.mouse_x<gfx.w-404 and gfx.mouse_y>=160 and gfx.mouse_y<209 then header_hint='Record: '..S.label()end
  color(C.line);gfx.line(gfx.w-400,168,gfx.w-400,201)
  button('Timeline',gfx.w-392,168,104,33,function()change_view('timeline')end,view=='timeline' and C.blue or nil)
  button('Takes',gfx.w-280,168,80,33,function()change_view('review')end,view=='review' and C.blue or nil)
  button('Tracks',gfx.w-192,168,88,33,function()change_view('tracks')end,view=='tracks' and C.blue or nil)
  button('Mix',gfx.w-96,168,72,33,function()change_view('mix')end,view=='mix' and C.blue or nil)
  color(C.line);gfx.line(24,217,gfx.w-24,217)
  if view=='timeline' then
   V.draw(24,226,gfx.w-48,gfx.h-311,recording)
  elseif view=='mix' then
   mix().draw(24,226,gfx.w-48,gfx.h-311)
  elseif view=='tracks' then
   track_view().draw(24,226,gfx.w-48,gfx.h-311,recording)
  else
  text('Passage',24,235,4)
  button('4 bars',122,226,78,34,function()M.loop_bars(4) end)
  button('8 bars',208,226,78,34,function()M.loop_bars(8) end)
  button('Loop selection',294,226,133,34,function()
   S.manual()
   local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false);if e<=s then error('Drag a time selection in the timeline first.',0) end
   R.GetSet_LoopTimeRange2(0,true,true,s,e,false);R.GetSetRepeat(1);R.SetEditCurPos2(0,s,true,false)
  end)
  button('Count-in...',435,226,120,34,function()R.Main_OnCommand(40363,0) end)
  local punch=R.GetToggleCommandStateEx(0,40076)==1
  button(punch and 'Punch on' or 'Punch off',563,226,w-587,34,function()S.manual();R.Main_OnCommand(punch and 40252 or 40076,0) end)
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  text(e>s and ('Selected: '..R.format_timestr_pos(s,'',2)..' to '..R.format_timestr_pos(e,'',2)) or 'Select a passage in the timeline to compare or comp.',25,272,3,C.muted,w-370)
  button('Clear selection',w-174,265,150,28,function()
   S.manual();R.Main_OnCommand(40020,0);status='Time selection and loop range cleared.'
  end,nil,not recording)
  local selected_count=#selected_rows();local single=not recording and selected_count==1
  text((S.mode()=='section' and 'Section takes' or 'Takes')..(selected_count>1 and (' / '..selected_count..' selected')or ''),24,307,4)
  button('Tempo...',w-322,297,94,34,tempo_menu,nil,not recording and #rows>0)
  button('Previous',w-220,297,92,34,function()select_step(-1) end,nil,not recording)
  button('Next',w-120,297,96,34,function()select_step(1) end,nil,not recording)
  local table_y=345; local table_end=gfx.h-180;local visible=math.max(1,math.floor((table_end-table_y)/42))
  local focus=chosen()
  if focus and focus.key~=review_focus then
   for i,row in ipairs(rows)do if row.key==focus.key then
    if i<=scroll then scroll=i-1 elseif i>scroll+visible then scroll=i-visible end
   end end
  end
  review_focus=focus and focus.key
  scroll=math.max(0,math.min(scroll,#rows-visible))
  if #rows==0 then
   text(#tracks==0 and 'Add an instrument to begin.' or 'Your recorded takes will appear here.',30,365,1,C.muted)
   text('Use one recording set for a single instrument or all microphones of a kit.',30,393,3,C.muted)
  else
   for i=scroll+1,math.min(#rows,scroll+visible) do
    local row=rows[i];local y=table_y+(i-scroll-1)*42
    color(selection.has(row.key) and {0.25,0.35,0.43} or C.surface);gfx.rect(24,y,w-48,38,1)
    if row.playing then color(C.blue);gfx.rect(24,y,4,38,1) end
    local name=row.name:match('^%d+$') and 'Take '..row.name or row.name
    text(name,39,y+10,1,C.text,175)
    local tempo=row.tempo or {label='Tempo ?'}
    text(tempo.label..(tempo.different and ' / different' or ''),220,y+11,3,tempo.different and C.gold or C.muted,200)
    text((row.favorite and '* 'or '')..(row.note~='' and row.note or 'Take mode follows selection'),425,y+11,3,row.note~='' and C.text or C.muted,w-460)
    if not recording then buttons[#buttons+1]={x=24,y=y,w=w-48,h=38,fn=function()select_take(row)end}end
   end
  end
  local fy=gfx.h-167
  button('Favorite',24,fy,100,35,function()take_action('favorite')end,nil,single)
  button('Take note',132,fy,110,35,function()annotate(false) end,nil,single)
  button('Passage note',250,fy,128,35,function()annotate(true) end,nil,single)
  button('Rename',386,fy,89,35,rename,nil,single)
  button(selected_count>1 and ('Delete '..selected_count..' takes')or 'Delete take',483,fy,160,35,function()take_action('delete')end,C.record,not recording and selected_count>0)
  button('Use in comp',w-207,fy,183,35,function()take_action('comp')end,C.blue,single)
  button('Comp',w-322,265,64,28,function()take_action('listen_comp')end,listen_mode=='comp'and C.blue or nil,not recording and comp_row~=nil)
  button('Take',w-254,265,68,28,function()take_action('listen_take')end,listen_mode=='take'and C.blue or nil,single)
  local cr=chosen();local sn=cr and e>s and M.section_note(cr.lane,s,e) or ''
  text(sn~='' and ('Passage note: '..sn) or 'Cmd-click: toggle takes / Shift-click: range. Delete removes whole passes; Cmd+Z in REAPER restores them.',25,fy+46,3,C.muted,w-50)
  section_sidebar(w+12,264,recording)
  end
  end
  color(C.line);gfx.line(24,gfx.h-78,gfx.w-24,gfx.h-78)
  text(header_hint or status,25,gfx.h-64,3,C.text,gfx.w-50)
  text(view=='projects'and 'P: back to song   N: new song   Up/Down: choose song   Enter: open song   Space: play/stop' or 'P: projects   S: track settings   Space: play/stop   R: record   N: another take   Left/Right: takes   Cmd/Ctrl+Z: undo',25,gfx.h-36,3,C.muted,gfx.w-50)
 end
 local modal=track_settings~=nil or template_settings~=nil
 if modal then
  buttons={};sliders={}
  if template_settings then draw_template_settings()else draw_track_settings()end
 end
 local down=gfx.mouse_cap&1==1
 local consumed=not modal and view=='timeline' and V.mouse(down,down and not mouse_down,R.GetPlayState()&4~=0)
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
 local over_tabs=set_tab_strip and gfx.mouse_x>=set_tab_strip.x and gfx.mouse_x<set_tab_strip.x+set_tab_strip.w and gfx.mouse_y>=set_tab_strip.y and gfx.mouse_y<set_tab_strip.y+set_tab_strip.h
 if not modal and over_tabs and (gfx.mouse_wheel~=0 or (gfx.mouse_hwheel or 0)~=0)then
  local wheel=(gfx.mouse_hwheel or 0)~=0 and gfx.mouse_hwheel or gfx.mouse_wheel
  set_tab_strip.move(wheel>0 and -1 or 1);gfx.mouse_wheel=0;gfx.mouse_hwheel=0
 end
 if gfx.mouse_wheel~=0 and not modal then
  local delta=gfx.mouse_wheel>0 and 1 or -1
  if view=='timeline' then V.wheel(delta)
  elseif view=='mix' then mix().wheel(delta)
  elseif view=='tracks' then track_view().wheel(delta)
  elseif view=='projects' then project_view().wheel(delta)
  elseif gfx.mouse_x>gfx.w-300 then section_scroll=section_scroll-delta else scroll=scroll-delta end
  gfx.mouse_wheel=0
 end
 gfx.mouse_hwheel=0
 if modal then gfx.mouse_wheel=0 end
 local ch=gfx.getchar()
 if modal and ch>=0 then
  if ch==27 or ch==13 then track_settings=nil;template_settings=nil end
  ch=0 -- Dialogs never trigger recording, playback, Undo, or take shortcuts.
 end
 if ch==26 or ch==25 then
  run(function()history(ch==25 or gfx.mouse_cap&8~=0)end);ch=0
 end
 if ch==27 and V.cancel()then ch=0 end
 if view=='mix' and X and X.key(ch)then ch=0 end
 if view=='projects'and P and P.key(ch)then ch=0 end
 if ch==112 or ch==80 then run(function()change_view(view=='projects'and 'timeline'or 'projects')end)
 elseif ch==109 or ch==77 then run(function()change_view('mix')end)
 elseif (ch==115 or ch==83)and view~='projects'and #tracks>0 then run(show_track_settings)
 elseif ch==32 then run(play) elseif ch==114 or ch==82 then run(M.record)
 elseif ch==110 or ch==78 then run(M.another)
 elseif ch==1818584692 and view~='tracks' then run(function()select_step(-1) end)
 elseif ch==1919379572 and view~='tracks' then run(function()select_step(1) end)
 elseif (ch==102 or ch==70)and view~='tracks' then run(function()with_row(function(row)M.favorite(row.lane) end) end)
 elseif ch==98 or ch==66 then run(mark_transition)
 end
 gfx.update();if ch>=0 and ch~=27 then R.defer(frame) end
end
frame()
