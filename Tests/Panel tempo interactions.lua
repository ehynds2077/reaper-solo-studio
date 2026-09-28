-- Runs the actual panel against a fake gfx surface, without controlling REAPER.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0
local function fixture(initial_view)
  local f={project='song',recording=false,tempo_map=false,bpm=120,volume=0.5,calls={},clock=0,rows={},set='scratch',errors={},labels={},sections={},view=initial_view or 'review'}
  local function call(kind,value) f.calls[#f.calls+1]={kind,value} end
  f.saved_comp={is_comp=true,key='saved-comp',lane=99,playing=true,name='Comp',note='',items={{s=0,e=24}}}
  local function activate(lane)
    if f.saved_comp then f.saved_comp.playing=lane==f.saved_comp.lane end
    for _,row in ipairs(f.rows)do row.playing=row.lane==lane end
  end
  local M={stopped=function()assert(not f.recording)end,finish_recorded_tempo=function()end,cancel_preview=function()end,ns='test',
    stop=function()f.playing=false end,
    use_in_comp=function(key,s,e)activate(99);call('comp',{key=key,s=s,e=e})end,
    listen_comp=function()assert(f.saved_comp);activate(99);call('back',true)end,
    require_tracks=function()return {'track'}end,tracks=function()return {'track'}end,
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
    time_precise=function()f.clock=f.clock+1;return f.clock end,
    GetExtState=function(_,key)return key=='panel_view' and f.view or ''end,SetExtState=function()end,
    OnPlayButton=function()f.playing=true end,GetPlayState=function()return f.recording and 4 or f.playing and 1 or 0 end,
    GetMediaTrackInfo_Value=function()return 0 end,GetMediaItemInfo_Value=function(it,k)return k=='D_POSITION' and it.s or it.e-it.s end,
    GetToggleCommandStateEx=function()return 0 end,
    GetSet_LoopTimeRange2=function()return 0,0 end,
    atexit=function()end,defer=function(fn)f.frame=fn end}
  local g={mouse_x=0,mouse_y=0,mouse_cap=0,mouse_wheel=0}
  for _,key in ipairs({'set','setfont','rect','line','circle','drawstr','update'}) do g[key]=function()end end
  g.measurestr=function(s)return #s*8,16 end
  g.init=function(_,w,h)g.w=w;g.h=h end
  g.dock=function()return 0 end
  g.getchar=function()return f.key or 0 end
  g.showmenu=function()return f.menu_choice or 0 end
  g.drawstr=function(s)f.labels[#f.labels+1]=s end
  local env=setmetatable({reaper=R,gfx=g,dofile=function(path)
    if path:match('solo_core.lua$') then return M end
    if path:match('solo_tempo.lua$') then return T end
    if path:match('solo_timeline.lua$') then return function(_,_,ui)f.timeline=ui;return {reset=function()end,cancel=function()return false end,draw=function()end,mouse=function()end,wheel=function()end}end end
    if path:match('solo_tracks_view.lua$')then return function()return {reset=function()f.track_reset=true end,draw=function()f.track_drawn=true end,wheel=function(delta)f.track_wheel=delta end}end end
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
local tf=fixture('tracks')
check(tf.track_drawn,'The saved Tracks tab opens the project-track interface')
tf.gfx.mouse_wheel=-120;tf.frame();check(tf.track_wheel==-1,'The Tracks tab routes scrolling to project tracks')
tf.project='new song';tf.frame();check(tf.track_reset,'Switching projects resets the Tracks view')
tf=fixture();tf.click(1075,40);check(tf.track_drawn,'The Tracks tab is reachable from the panel navigation')
tf.key=1919379572;tf.frame();check(#tf.calls==0,'Track view arrow keys cannot accidentally switch a hidden take')
local f=fixture()
check(#f.calls==0,'Opening panel changes no settings')
f.mouse(140,256,true);f.mouse(197,256,true)
check(#f.calls==0,'Tempo drag previews without repeated edits')
f.mouse(197,256,false)
check(#f.calls==1 and f.calls[1][1]=='tempo' and f.bpm==160,'Tempo drag commits once on release')
f=fixture();f.mouse(500,256,true);f.mouse(405,256,false)
check(#f.calls==1 and f.calls[1][1]=='volume' and f.volume==0,'Volume slider can reach mute')
f=fixture();f.mouse(500,256,true);f.mouse(800,256,false)
check(f.volume==1,'Dragging past volume rail clamps at maximum')
f=fixture();f.mouse(140,256,true);f.project='other song';f.mouse(250,256,false)
check(#f.calls==0,'Project switch cancels pending slider edit')
f=fixture();f.mouse(140,256,true);f.recording=true;f.mouse(250,256,false)
check(#f.calls==0,'Starting recording cancels pending tempo edit')
f=fixture();f.tempo_map=true;f.mouse(140,256,true);f.mouse(250,256,false)
check(#f.calls==0,'Tempo-map project disables tempo slider')
f=fixture();f.mouse(750,230,true);f.mouse(750,230,false)
check(#f.calls==1 and f.calls[1][1]=='sounds','Click sound button opens native sound settings')
local function take(key,lane,playing)return {key=key,lane=lane,name=key,note='',playing=playing,favorite=false,items={{s=0,e=8}}}end
local function audition_button(f)f.click(680,353)end
local function comp_button(f)f.click(610,353)end
local function last(f)return f.calls[#f.calls]end
f=fixture();f.rows={take('Short take',0),take('Other take',1)};f.frame()
f.click(400,435)
check(#f.calls==0,'Comp mode lets a take-list click select without switching audio')
audition_button(f)
check(last(f)[1]=='audition'and last(f)[2]==0 and not f.playing,'Take toggle selects the highlighted lane without starting stopped transport')
f.click(400,477)
check(last(f)[2]==1 and f.timeline.listen_mode()=='take','Take mode follows a new take-list selection automatically')
f.click(540,579)
check(last(f)[1]=='delete'and last(f)[2]=='Other take'and f.rows[1].playing and #f.rows==1,'Deleting the playing take automatically listens to its selected neighbor')
comp_button(f);check(last(f)[1]=='back'and not f.playing,'Comp toggle returns to saved choices without starting playback')
f=fixture();f.rows={take('Take 1',0)};f.recording=true;f.frame()
f.click(540,579);audition_button(f);comp_button(f)
check(#f.calls==0 and #f.rows==1,'Deletion and playback toggles are disabled during recording')
f.key=1919379572;f.frame();f.key=nil
check(#f.calls==0,'Keyboard browsing cannot switch lanes while recording')
f=fixture();f.rows={take('Old take',0,true)};f.saved_comp.playing=false;f.frame();f.recording=true;f.frame()
f.rows={take('Old take',0,false),take('New take',1,true)};f.recording=false;f.frame()
f.click(540,579)
check(f.calls[1]and f.calls[1][2]=='New take','After Stop the new pass becomes the selected take for review or deletion')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,477);f.click(540,579)
check(last(f)[2]=='Middle'and f.timeline.chosen().key=='Last'and #f.calls==1,'Deleting in Comp mode selects the next neighbor and preserves comp playback')
audition_button(f);f.click(540,579)
check(f.calls[3][2]=='Last'and f.rows[1].playing and f.timeline.chosen().key=='First','Deleting the final take in Take mode selects and plays the previous survivor')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,4);audition_button(f)
check(#f.calls==0,'Take toggle is disabled when several takes are selected')
f.click(540,579)
check(f.calls[1][2]=='First,Last'and #f.rows==1,'Cmd-click selects disjoint takes and Delete submits one batch')
audition_button(f);check(last(f)[2]==1,'After batch deletion the nearest surviving neighbor is selected')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,8);f.click(540,579)
check(f.calls[1][2]=='First,Middle,Last'and #f.rows==0,'Shift-click selects an inclusive range for batch deletion')
f.click(540,579);check(#f.calls==1,'Deleting every take leaves no selection or repeat deletion')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,4);f.click(400,435,4);f.click(540,579)
check(f.calls[1][2]=='Last','Cmd-click toggles a selected take out of the batch')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,477);f.click(400,519,4);f.delete_fail=true;f.click(540,579)
check(#f.rows==3 and #f.errors==1,'Failed batch deletion leaves the take list intact')
f.delete_fail=false;f.click(540,579)
check(f.calls[1][2]=='Middle,Last','Failed deletion preserves the selected batch for retry')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,4);f.filter={Last=true};f.frame();f.click(540,579)
check(f.calls[1][2]=='Last'and #f.rows==2,'Filtered-out takes are not silently retained in the deletion selection')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,4);f.set='guitar';f.rows={take('Guitar',0)};f.frame();f.click(540,579)
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
f.timeline.take_action('listen_take');f.click(250,110)
check(not f.playing and f.timeline.listen_mode()=='take'and f.rows[2].playing,'Stop preserves the chosen Take playback lane')
f.click(250,110);check(f.playing and f.rows[2].playing,'Play resumes the selected lane without another audition action')
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
