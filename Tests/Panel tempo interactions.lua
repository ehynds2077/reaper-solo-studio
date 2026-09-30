-- Runs the actual panel against a fake gfx surface, without controlling REAPER.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0
local function fixture(initial_view)
  local f={project='song',recording=false,tempo_map=false,bpm=120,volume=0.5,calls={},clock=0,rows={},set='scratch',errors={},labels={},sections={},extstate={},view=initial_view or 'review'}
  local function call(kind,value) f.calls[#f.calls+1]={kind,value} end
  f.track_list={'track'};f.track_values={track={}};f.selected_tracks={'track'}
  f.saved_comp={is_comp=true,key='saved-comp',lane=99,playing=true,name='Comp',note='',items={{s=0,e=24}}}
  local function activate(lane)
    if f.saved_comp then f.saved_comp.playing=lane==f.saved_comp.lane end
    for _,row in ipairs(f.rows)do row.playing=row.lane==lane end
  end
  local M={stopped=function()assert(not f.recording)end,finish_recorded_tempo=function()end,cancel_preview=function()end,ns='test',
    history=function(redo)
      local label=redo and f.redo_label or f.undo_label
      if not label or label==''then return end
      call(redo and 'redo'or 'undo',label)
      if redo then f.undo_label=label;f.redo_label=nil else f.redo_label=label;f.undo_label=nil end
      return label
    end,
    stop=function()f.playing=false end,
    use_in_comp=function(key,s,e)activate(99);call('comp',{key=key,s=s,e=e})end,
    listen_comp=function()assert(f.saved_comp);activate(99);call('back',true)end,
    require_tracks=function()return f.track_list end,tracks=function()return f.track_list end,
    track_name=function(tr)return tr end,
    selected=function()return f.selected_tracks end,
    capture=function(name)call('capture',name)end,
    add_instrument=function(kind,names)call('add_instrument',{kind=kind,names=names})end,
    arm=function()call('arm',f.set);for _,tr in ipairs(f.track_list)do f.track_values[tr].I_RECARM=1 end end,
    inputs=function(values)call('inputs',values)end,
    edit=function(_,fn)assert(not f.recording);fn()end,
    lanes=function()local rows={};for _,row in ipairs(f.rows)do rows[#rows+1]=row end;if f.saved_comp then rows[#rows+1]=f.saved_comp end;return rows end,
    row_for_key=function(key)for _,row in ipairs(f.rows)do if row.key==key then return row end end end,
    audition=function(lane,whole_lane)assert(not f.recording);assert(whole_lane,'Toggle must play the whole source lane');assert(not f.audition_fail,'Simulated audition failure');activate(lane);call('audition',lane)end,
    delete_takes=function(rows,listen_key)
      if f.delete_fail then error('Simulated failure')end
      local keys={};for _,row in ipairs(rows)do keys[#keys+1]=row.key end
      call('delete',table.concat(keys,','))
      if listen_key then for _,row in ipairs(f.rows)do if row.key==listen_key then activate(row.lane)end end end
      for i=#f.rows,1,-1 do for _,key in ipairs(keys)do if f.rows[i].key==key then table.remove(f.rows,i);break end end end
    end,
    get=function(key)return key=='active' and f.set or 'Scratch'end,
    sets=function()return {{id='scratch',name='Scratch'}}end,message=function(s)f.errors[#f.errors+1]=s end}
  M.sections=function()return {recover_leadin=function()end,filter_takes=function(rows)if not f.filter then return rows end;local out={};for _,row in ipairs(rows)do if f.filter[row.key]then out[#out+1]=row end end;return out end,list=function()return f.sections end,
    mode=function()return f.section and 'section' or ''end,active=function()return f.section end,label=function()return 'Full song'end,
    looping=function()return false end,snapping=function()return true end}end
  local T={min_bpm=20,max_bpm=300,bpm=function()return f.bpm end,
    tempo_enabled=function()return not f.recording and not f.tempo_map end,
    set_bpm=function(v)f.bpm=v;call('tempo',v)end,
    click_db=function()return -12 end,volume_position=function()return f.volume end,
    position_db=function(v)return v==0 and -math.huge or v*60-60 end,
    format_db=function(v)return tostring(v)end,
    set_volume=function(v)f.volume=v;call('volume',v)end,
    set_click_db=function(v)call('db',v)end,sound_settings=function()call('sounds',true)end}
  local R={ValidatePtr2=function()return true end,EnumProjects=function()return f.project end,
    Undo_CanUndo2=function()return f.undo_label end,Undo_CanRedo2=function()return f.redo_label end,
    time_precise=function()f.clock=f.clock+1;return f.clock end,
    GetExtState=function(_,key)return key=='panel_view' and f.view or f.extstate[key]or ''end,SetExtState=function(_,key,value)f.extstate[key]=value end,
    OnPlayButton=function()f.playing=true end,GetPlayState=function()return f.recording and 4 or f.playing and 1 or 0 end,
    GetMediaTrackInfo_Value=function(tr,key)return (f.track_values[tr]or {})[key]or 0 end,
    SetMediaTrackInfo_Value=function(tr,key,value)f.track_values[tr][key]=value;call('monitor',value)end,
    GetNumAudioInputs=function()return 16 end,GetInputChannelName=function(i)return 'Input '..(i+1)end,
    GetUserInputs=function()if f.on_input then f.on_input()end;return f.input_ok~=false,f.input_reply or '1'end,
    GetMediaItemInfo_Value=function(it,k)return k=='D_POSITION' and it.s or it.e-it.s end,
    GetToggleCommandStateEx=function()return 0 end,
    GetSet_LoopTimeRange2=function()return 0,0 end,
    atexit=function(fn)f.cleanup=fn end,defer=function(fn)f.frame=fn end}
  local g={mouse_x=0,mouse_y=0,mouse_cap=0,mouse_wheel=0}
  for _,key in ipairs({'set','setfont','rect','line','circle','drawstr','update'}) do g[key]=function()end end
  g.measurestr=function(s)return #s*8,16 end
  g.init=function(_,w,h)g.w=w;g.h=h end
  g.dock=function()return 0 end
  g.quit=function()f.window_closed=true end
  g.getchar=function()return f.key or 0 end
  g.showmenu=function(menu)f.menu={text=menu,x=g.x,y=g.y};return f.menu_choice or 0 end
  g.drawstr=function(s)f.labels[#f.labels+1]=s end
  local env=setmetatable({reaper=R,gfx=g,dofile=function(path)
    if path:match('solo_core.lua$') then return M end
    if path:match('solo_bounces.lua$')then return {identity=function()return {title=f.song_title or 'Current song'}end}end
    if path:match('solo_tempo.lua$') then return T end
    if path:match('solo_timeline.lua$') then return function(_,_,ui)f.timeline=ui;return {reset=function()end,cancel=function()return false end,
      cancel_drag=function()local had=f.pending_drag;f.pending_drag=false;return had end,history_changed=function()f.history_refreshed=true end,
      draw=function()end,mouse=function()f.timeline_mouse=(f.timeline_mouse or 0)+1 end,wheel=function()f.timeline_wheel=true end}end end
    if path:match('solo_tracks_view.lua$')then return function()return {reset=function()f.track_reset=true end,draw=function()f.track_drawn=true end,wheel=function(delta)f.track_wheel=delta end}end end
    if path:match('solo_projects_view.lua$')then return function(_,ui,options)
      f.projects_ui=ui;f.projects_options=options
      return {reset=function()f.projects_reset=true end,draw=function()f.projects_drawn=true end,
       wheel=function(delta)f.projects_wheel=delta end,key=function(ch)if ch==110 or ch==114 or ch==1818584692 then f.project_key=ch;return true end;return false end}
    end end
    if path:match('solo_mix.lua$')then return function()return {draw=function()f.mix_drawn=true end,poll=function()end,busy=function()return f.mix_busy end,
     close=function()f.mix_closed=(f.mix_closed or 0)+1 end,key=function()return false end}end end
    if path:match('solo_take_selection.lua$')then return dofile(path)end
    error('Unexpected module '..path)
  end},{__index=_G})
  assert(loadfile(root..'/Scripts/Solo Studio - Open recording panel.lua','t',env))()
  function f.mouse(x,y,down,mods)
    g.mouse_x=x;g.mouse_y=y;g.mouse_cap=(down and 1 or 0)|(mods or 0)
    f.frame()
  end
  function f.click(x,y,mods)f.mouse(x,y,true,mods);f.mouse(x,y,false,mods)end
  f.gfx=g;return f
end
local function check(ok,name)assert(ok,name);passed=passed+1;print('PASS: '..name)end
local function labeled(f,label)for _,v in ipairs(f.labels)do if v==label then return true end end;return false end
local function open_template(f)f.menu_choice=5;f.click(f.gfx.w-90,192)end
local template=fixture('timeline')
check(not labeled(template,'Use selected tracks'),'Existing-track capture is absent from the main toolbar')
open_template(template)
check(template.menu.x==1036 and template.menu.y==209 and labeled(template,'Create new template')and labeled(template,'Use selected tracks'),'Instrument menu anchors below its button and opens the template window')
local template_gestures=template.timeline_mouse
template.click(40,139);template.key=114;template.frame();template.key=32;template.frame();template.key=26;template.frame();template.key=nil
template.gfx.mouse_wheel=-120;template.frame()
check(#template.calls==0 and #template.errors==0 and template.timeline_mouse==template_gestures and not template.timeline_wheel,'Template window blocks background recording, transport, history, and timeline gestures')
template.selected_tracks={'Kick','Snare'};template.labels={};template.frame()
check(labeled(template,'2 selected tracks')and labeled(template,'Kick')and labeled(template,'Snare'),'Template preview follows the current REAPER track selection')
template.input_ok=false;template.click(805,575);template.labels={};template.frame()
check(#template.calls==0 and labeled(template,'Create new template'),'Cancelling the name prompt keeps the template window available')
template.input_ok=true;template.input_reply='Drums';template.click(805,575);template.labels={};template.frame()
check(template.calls[1][1]=='capture'and template.calls[1][2]=='Drums'and not labeled(template,'Create new template'),'Naming the selected tracks captures their set and closes the template window')
template=fixture('timeline');template.gfx.w=1400;template.frame();open_template(template)
check(template.menu.x==1236 and template.menu.y==209,'Instrument menu follows the button when the panel is resized')
template.key=27;template.frame();template.key=nil;template.labels={};template.frame()
check(not labeled(template,'Create new template')and not template.window_closed,'Escape dismisses the template without closing Solo Studio')
for _,lock in ipairs({'empty','recording','mix_busy'})do
 template=fixture(lock=='mix_busy'and 'mix'or 'timeline');open_template(template)
 if lock=='empty'then template.selected_tracks={}else template[lock]=true end
 template.click(805,575)
 check(#template.calls==0 and #template.errors==0,'Template capture is disabled for '..lock)
end
for _,change in ipairs({'project','selection'})do
 template=fixture('timeline');open_template(template)
 template.on_input=function()if change=='project'then template.project='another song'else template.selected_tracks={'another track'}end end
 template.click(805,575)
 check(#template.calls==0 and #template.errors==1,'Name prompt cannot capture changed '..change)
end
template=fixture('timeline');open_template(template);template.project='another song';template.labels={};template.frame()
check(not labeled(template,'Create new template'),'Changing projects dismisses the previous template window')
template=fixture('timeline');template.menu_choice=2;template.click(1105,192)
check(template.calls[1][1]=='add_instrument'and template.calls[1][2].kind=='Guitar','Built-in instrument choices still create their usual tracks')
local settings=fixture('timeline')
check(labeled(settings,'Track settings...')and not labeled(settings,'Arm set')and not labeled(settings,'Inputs...')and not labeled(settings,'Monitor off'),'Toolbar replaces the three seldom-used controls with Track settings')
settings.click(1090,136)
check(labeled(settings,'Track settings')and labeled(settings,'Assign inputs...')and labeled(settings,'Arm set')and labeled(settings,'Turn on'),'Track settings exposes inputs, arming, and monitoring together')
local gestures=settings.timeline_mouse
settings.click(40,139);settings.key=114;settings.frame();settings.key=32;settings.frame();settings.key=26;settings.frame();settings.key=nil
settings.gfx.mouse_wheel=-120;settings.frame()
check(#settings.calls==0 and #settings.errors==0 and settings.timeline_mouse==gestures and not settings.timeline_wheel,'Settings consume background clicks, record/play/undo shortcuts, and timeline gestures')
settings.click(815,395);check(settings.calls[1][1]=='arm','Arm set remains available inside settings')
settings.click(815,473);check(settings.track_values.track.I_RECMON==1,'Monitoring can be enabled inside settings')
settings.click(815,473);check(settings.track_values.track.I_RECMON==0,'Monitoring can be disabled inside settings')
settings.input_reply='15';settings.click(815,317)
check(settings.calls[#settings.calls][1]=='inputs'and settings.calls[#settings.calls][2][1]==15,'Input assignment uses the selected recording set from settings')
settings.key=27;settings.frame();settings.key=nil;settings.labels={};settings.frame()
check(not labeled(settings,'Assign inputs...')and not settings.window_closed,'Escape closes settings without closing Solo Studio')
settings.click(1090,136);settings.click(845,219);settings.labels={};settings.frame()
check(not labeled(settings,'Assign inputs...'),'Done closes the settings dialog')
settings.key=115;settings.frame();settings.key=nil;settings.labels={};settings.frame()
check(labeled(settings,'Track settings'),'S opens Track settings without recording or changing the project')
settings=fixture('timeline');settings.click(1090,136);settings.project='different';settings.labels={};settings.frame()
check(not labeled(settings,'Assign inputs...'),'Native project changes dismiss settings for the previous song')
settings=fixture('timeline');settings.click(1090,136);settings.set='guitar';settings.labels={};settings.frame()
check(not labeled(settings,'Assign inputs...'),'Recording-set changes dismiss stale settings')
for _,lock in ipairs({'recording','mix_busy'})do
 settings=fixture(lock=='mix_busy'and 'mix'or 'timeline');settings[lock]=true;settings.click(1090,136)
 settings.click(815,317);settings.click(815,395);settings.click(815,473)
 check(#settings.calls==0,'Settings edits are disabled during '..lock)
end
settings=fixture('timeline');settings.click(1090,136);settings.on_input=function()settings.set='another set'end;settings.click(815,317)
check(#settings.calls==0 and settings.errors[#settings.errors]:find('recording set changed',1,true),'Input dialog cannot apply changes after its recording set changes')
settings=fixture('timeline');settings.track_list={'track','second'};settings.track_values.second={I_RECMON=2};settings.click(1090,136)
check(labeled(settings,'Mixed: some tracks have monitoring on.')and labeled(settings,'Turn off'),'Mixed monitoring is identified instead of using only the first microphone')
settings.click(815,473)
check(settings.track_values.track.I_RECMON==0 and settings.track_values.second.I_RECMON==0,'Mixed monitoring switches the whole set off together')
local pf=fixture('projects');check(pf.projects_drawn,'Projects can be restored as the saved panel view')
pf.gfx.mouse_wheel=-120;pf.frame();check(pf.projects_wheel==-1,'Project library receives scrolling')
pf.key=110;pf.frame();pf.key=nil;check(pf.project_key==110 and #pf.calls==0,'Projects handles N without triggering another recording take')
pf.key=114;pf.frame();pf.key=nil;check(pf.project_key==114 and #pf.calls==0,'Recording hotkey is consumed while browsing songs')
pf.projects_ui.opened('Ready');pf.frame();pf.projects_drawn=false;pf.frame();check(not pf.projects_drawn,'Opening a project returns the panel to its timeline')
pf.key=112;pf.frame();pf.key=nil;pf.frame();check(pf.projects_drawn,'P opens Projects from the recording workspace')
pf=fixture();pf.click(998,40);check(pf.projects_drawn,'Projects button opens the library')
pf.project='new project';pf.frame();check(pf.projects_reset,'Native project changes invalidate the project list')
pf=fixture('mix');pf.project='another project';pf.frame();check(pf.mix_closed==1,'Changing native project releases the old mix session view')
local launched=fixture('mix');launched.mix_busy=true;launched.extstate.panel_raise='1';launched.frame()
check(launched.window_closed and launched.extstate.panel_raise==''and launched.extstate.panel_open=='1','Desktop relaunch raises the existing panel and consumes its request')
check(not launched.mix_closed and launched.mix_busy and #launched.calls==0,'Raising the panel preserves the mix worker and project without cleanup')
launched.cleanup();check(launched.extstate.panel_open==''and launched.mix_closed==1,'Panel exit clears its nonpersistent launcher marker')
local hf=fixture('timeline');hf.undo_label='Solo Studio: move comp boundary';hf.playing=true;hf.click(805,40)
check(hf.calls[1][1]=='undo'and hf.history_refreshed and hf.playing,'Undo button reverses the native edit, refreshes the timeline, and preserves playback')
hf.click(889,40);check(hf.calls[2][1]=='redo','Redo button reapplies the native boundary edit')
hf=fixture('timeline');hf.undo_label='Solo Studio: move comp boundary';hf.key=26;hf.frame();hf.key=nil
check(hf.calls[1][1]=='undo','Cmd/Ctrl+Z works while the panel has focus')
hf.gfx.mouse_cap=8;hf.key=26;hf.frame();hf.key=nil
check(hf.calls[2][1]=='redo','Shift+Cmd/Ctrl+Z redoes while the panel has focus')
hf=fixture();hf.redo_label='Solo Studio: move comp boundary';hf.key=25;hf.frame()
check(hf.calls[1][1]=='redo','Ctrl+Y also performs Redo')
hf=fixture('timeline');hf.undo_label='Solo Studio: move comp boundary';hf.pending_drag=true;hf.key=26;hf.frame();hf.key=nil
check(#hf.calls==0 and not hf.pending_drag,'Undo during a drag cancels the preview before touching committed history')
hf=fixture();hf.click(805,40);hf.key=26;hf.frame();hf.key=nil
check(#hf.calls==0 and #hf.errors==0,'Empty history disables Undo and shortcuts are harmless')
hf=fixture();hf.undo_label='Solo Studio: move comp boundary';hf.recording=true;hf.click(805,40);hf.key=26;hf.frame()
check(#hf.calls==0,'Recording blocks both Undo buttons and shortcuts')
local tf=fixture('tracks')
check(tf.track_drawn,'The saved Tracks tab opens the project-track interface')
tf.gfx.mouse_wheel=-120;tf.frame();check(tf.track_wheel==-1,'The Tracks tab routes scrolling to project tracks')
tf.project='new song';tf.frame();check(tf.track_reset,'Switching projects resets the Tracks view')
tf=fixture();tf.click(268,237);check(tf.track_drawn,'The Tracks tab is reachable from the panel navigation')
tf.key=1919379572;tf.frame();check(#tf.calls==0,'Track view arrow keys cannot accidentally switch a hidden take')
for _,mode in ipairs({'timeline','review','tracks','mix','projects'})do
 local shared=fixture(mode)
 shared.mouse(300,84,true);shared.mouse(335,84,false)
 shared.mouse(735,84,true);shared.mouse(662,84,false)
 shared.click(1060,84)
 check(#shared.calls==3 and shared.calls[1][1]=='tempo'and shared.bpm==160 and shared.calls[2][1]=='volume'and shared.volume==0 and shared.calls[3][1]=='sounds','Shared tempo, click volume and sound controls work in '..mode)
end
local mf=fixture('mix');mf.mix_busy=true;mf.mouse(300,84,true);mf.mouse(335,84,false)
check(#mf.calls==0,'Shared tempo is locked during an active AI mix')
mf=fixture('timeline');mf.mouse(300,84,true);mf.key=112;mf.frame();mf.key=nil;mf.mouse(335,84,false)
check(#mf.calls==0 and mf.projects_drawn,'Changing view cancels a pending tempo drag')
local f=fixture()
check(#f.calls==0,'Opening panel changes no settings')
f.mouse(300,84,true);f.mouse(335,84,true)
check(#f.calls==0,'Tempo drag previews without repeated edits')
f.mouse(335,84,false)
check(#f.calls==1 and f.calls[1][1]=='tempo' and f.bpm==160,'Tempo drag commits once on release')
f=fixture();f.mouse(735,84,true);f.mouse(662,84,false)
check(#f.calls==1 and f.calls[1][1]=='volume' and f.volume==0,'Volume slider can reach mute')
f=fixture();f.mouse(735,84,true);f.mouse(890,84,false)
check(f.volume==1,'Dragging past volume rail clamps at maximum')
f=fixture();f.mouse(300,84,true);f.project='other song';f.mouse(360,84,false)
check(#f.calls==0,'Project switch cancels pending slider edit')
f=fixture();f.mouse(300,84,true);f.recording=true;f.mouse(360,84,false)
check(#f.calls==0,'Starting recording cancels pending tempo edit')
f=fixture();f.tempo_map=true;f.mouse(300,84,true);f.mouse(360,84,false)
check(#f.calls==0,'Tempo-map project disables tempo slider')
f=fixture();f.mouse(1060,84,true);f.mouse(1060,84,false)
check(#f.calls==1 and f.calls[1][1]=='sounds','Click sound button opens native sound settings')
local function take(key,lane,playing)return {key=key,lane=lane,name=key,note='',playing=playing,favorite=false,items={{s=0,e=8}}}end
local function audition_button(f)f.click(680,325)end
local function comp_button(f)f.click(610,325)end
local function last(f)return f.calls[#f.calls]end
f=fixture();f.rows={take('Short take',0),take('Other take',1)};f.frame()
f.click(400,407)
check(#f.calls==0,'Comp mode lets a take-list click select without switching audio')
audition_button(f)
check(last(f)[1]=='audition'and last(f)[2]==0 and not f.playing,'Take toggle selects the highlighted lane without starting stopped transport')
f.click(400,449)
check(last(f)[2]==1 and f.timeline.listen_mode()=='take','Take mode follows a new take-list selection automatically')
f.click(540,603)
check(last(f)[1]=='delete'and last(f)[2]=='Other take'and f.rows[1].playing and #f.rows==1,'Deleting the playing take automatically listens to its selected neighbor')
comp_button(f);check(last(f)[1]=='back'and not f.playing,'Comp toggle returns to saved choices without starting playback')
f=fixture();f.rows={take('Take 1',0)};f.recording=true;f.frame()
f.click(540,603);audition_button(f);comp_button(f)
check(#f.calls==0 and #f.rows==1,'Deletion and playback toggles are disabled during recording')
f.key=1919379572;f.frame();f.key=nil
check(#f.calls==0,'Keyboard browsing cannot switch lanes while recording')
f=fixture();f.rows={take('Old take',0,true)};f.saved_comp.playing=false;f.frame();f.recording=true;f.frame()
f.rows={take('Old take',0,false),take('New take',1,true)};f.recording=false;f.frame()
f.click(540,603)
check(f.calls[1]and f.calls[1][2]=='New take','After Stop the new pass becomes the selected take for review or deletion')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,449);f.click(540,603)
check(last(f)[2]=='Middle'and f.timeline.chosen().key=='Last'and #f.calls==1,'Deleting in Comp mode selects the next neighbor and preserves comp playback')
audition_button(f);f.click(540,603)
check(f.calls[3][2]=='Last'and f.rows[1].playing and f.timeline.chosen().key=='First','Deleting the final take in Take mode selects and plays the previous survivor')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,407);f.click(400,491,4);audition_button(f)
check(#f.calls==0,'Take toggle is disabled when several takes are selected')
f.click(540,603)
check(f.calls[1][2]=='First,Last'and #f.rows==1,'Cmd-click selects disjoint takes and Delete submits one batch')
audition_button(f);check(last(f)[2]==1,'After batch deletion the nearest surviving neighbor is selected')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,407);f.click(400,491,8);f.click(540,603)
check(f.calls[1][2]=='First,Middle,Last'and #f.rows==0,'Shift-click selects an inclusive range for batch deletion')
f.click(540,603);check(#f.calls==1,'Deleting every take leaves no selection or repeat deletion')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,407);f.click(400,491,4);f.click(400,407,4);f.click(540,603)
check(f.calls[1][2]=='Last','Cmd-click toggles a selected take out of the batch')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,449);f.click(400,491,4);f.delete_fail=true;f.click(540,603)
check(#f.rows==3 and #f.errors==1,'Failed batch deletion leaves the take list intact')
f.delete_fail=false;f.click(540,603)
check(f.calls[1][2]=='Middle,Last','Failed deletion preserves the selected batch for retry')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,407);f.click(400,491,4);f.filter={Last=true};f.frame();f.click(540,603)
check(f.calls[1][2]=='Last'and #f.rows==2,'Filtered-out takes are not silently retained in the deletion selection')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,407);f.click(400,491,4);f.set='guitar';f.rows={take('Guitar',0)};f.frame();f.click(540,603)
check(f.calls[1][2]=='Guitar','Changing instruments clears the previous multiselection')
f=fixture('timeline');f.rows={take('Full',0),take('Partial',1)};f.rows[1].items[1].e=24;f.rows[2].items={{s=10,e=14}}
f.sections={{s=0,e=8},{s=8,e=16},{s=16,e=24}};f.section=f.sections[1];f.frame()
f.timeline.select(f.rows[2],{s=10,e=14},11)
check(#f.calls==0 and f.timeline.listen_mode()=='comp','Selecting a timeline clip in Comp mode leaves saved comp playing')
f.timeline.take_action('listen_take')
check(last(f)[2]==1 and not f.playing,'Take mode plays the complete partial lane even outside the selected recording section')
f.playing=true;f.timeline.select(f.rows[1],{s=0,e=24},12)
check(last(f)[2]==0 and f.playing,'Clicking another timeline clip switches its whole lane without stopping playback')
f.timeline.take_action('comp');local committed=last(f)[2]
check(committed.key=='Full'and committed.s==8 and committed.e==16 and f.timeline.listen_mode()=='comp'and f.playing,'Use in comp keeps the clicked section, returns to Comp, and preserves playback')
local temporary=take('Temporary',3);temporary.is_preview=true;f.rows[#f.rows+1]=temporary;f.frame()
check(#f.timeline.rows()==2 and f.timeline.comp()==f.saved_comp,'Comp and legacy temporary lanes stay out of source take selection')
f.timeline.select(f.rows[2],{s=10,e=14},11);local count=#f.calls
f.key=1919379572;f.frame();f.key=nil
check(#f.calls==count and f.timeline.chosen().key=='Full','Arrow keys browse selections without changing audio in Comp mode')
f.timeline.take_action('listen_take');f.key=1919379572;f.frame();f.key=nil
check(last(f)[2]==1 and f.playing,'Arrow keys automatically switch playback in Take mode')
f.timeline.take_action('listen_comp')
check(last(f)[1]=='back'and f.playing and f.timeline.chosen().key=='Partial','Comp toggle preserves playback and highlighted source take')
f.timeline.take_action('listen_take');f.click(250,134)
check(not f.playing and f.timeline.listen_mode()=='take'and f.rows[2].playing,'Stop preserves the chosen Take playback lane')
f.click(250,134);check(f.playing and f.rows[2].playing,'Play resumes the selected lane without another audition action')
f.gfx.mouse_cap=4;count=#f.calls;f.timeline.select(f.rows[1]);f.gfx.mouse_cap=0
check(f.timeline.selection_count()==2 and #f.calls==count,'Multiselection in Take mode keeps the current audio lane')
f.timeline.take_action('listen_comp');check(f.timeline.listen_mode()=='comp','Comp remains available with multiple sources selected')
f.timeline.select(f.rows[1]);f.audition_fail=true
local ok=pcall(f.timeline.take_action,'listen_take')
check(not ok and f.saved_comp.playing and f.timeline.listen_mode()=='comp','Failed Take activation preserves Comp playback and mode')
f=fixture('timeline');f.saved_comp=nil;f.rows={take('First',0,true),take('Second',1)};f.frame();f.timeline.select(f.rows[2])
check(last(f)[2]==1 and f.timeline.listen_mode()=='take','Before a comp exists, single selection directly activates the source take')
f.saved_comp={is_comp=true,key='guitar-comp',lane=99,playing=true,name='Comp',items={{s=0,e=24}}};f.set='guitar';f.rows={take('Guitar',0)};f.frame()
check(f.timeline.listen_mode()=='comp','Changing instruments reflects the new set native playback mode')
f=fixture();local preview_label=false;for _,label in ipairs(f.labels)do if label=='Preview'then preview_label=true end end
check(not preview_label,'The Takes view no longer exposes an explicit Preview button')
f=fixture('timeline');f.rows={take('Current',0),take('Slow',1),take('Unknown',2),take('Mixed',3)}
f.rows[1].tempo={label='120 BPM',bpm=120};f.rows[2].tempo={label='100 BPM',bpm=100,different=true};f.rows[3].tempo={unknown=true,label='Tempo ?'};f.rows[4].tempo={label='Mixed tempo',mixed=true,unknown=true};f.frame()
f.menu_choice=1;f.timeline.tempo_menu()
check(f.timeline.selection_count()==1 and f.timeline.selected('Slow')and #f.calls==0,'Tempo menu selects only known mismatches without deleting anything')
f.timeline.take_action('delete');check(f.calls[1][2]=='Slow'and #f.rows==3,'Existing batch delete removes the selected tempo mismatch')
f.menu_choice=2;f.timeline.tempo_menu()
check(f.timeline.selection_count()==1 and f.timeline.selected('Unknown'),'Unknown-tempo selection excludes mixed takes with some known clips')
f.menu_choice=1;f.timeline.tempo_menu();f.frame()
check(f.timeline.selection_count()==0,'No tempo matches leaves an empty selection instead of selecting the first take')
print(passed..' panel interaction checks passed.')
