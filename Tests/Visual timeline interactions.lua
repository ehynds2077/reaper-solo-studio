-- Run the real timeline and region modules with a synthetic 120 BPM project.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={regions={},state={},edits=0,project='a',cursor=0,recording=false,errors={},buttons={},takes={},draws={},labels={},active_set='drums',clock=0}
 local serial=0
 reaper={
  time_precise=function()return f.clock end,
  ValidatePtr2=function(_,it)return not it.deleted end,
  GetMediaItemInfo_Value=function(it,key)assert(not it.deleted,'Stale item');return key=='D_POSITION' and it.s or it.e-it.s end,
  EnumProjects=function()return f.project end,GetProjectLength=function()return 32 end,
  GetPlayState=function()return f.recording and 4 or 0 end,GetCursorPosition=function()return f.cursor end,
  SetEditCurPos2=function(_,p)f.cursor=p end,Main_OnCommand=function()end,GetSetRepeat=function()end,
  GetSet_LoopTimeRange2=function()return 0,0 end,
  TimeMap_GetMeasureInfo=function(_,m)return m*2,m*4,(m+1)*4,4,4,120 end,
  TimeMap2_timeToBeats=function(_,t)local m=math.floor(t/2);return (t-m*2)*2,m,4 end,
  TimeMap2_beatsToTime=function(_,b,m)return m*2+b/2 end,
  format_timestr_pos=function(t)local m=math.floor(t/2);return string.format('%d.%d.00',m+1,math.floor((t-m*2)*2)+1)end,
  parse_timestr_pos=function(s)local m,b,c=s:match('^(%d+)%.(%d+)%.?(%d*)$');return (tonumber(m)-1)*2+(tonumber(b)-1+(tonumber(c)or 0)/100)/2 end,
  EnumProjectMarkers3=function(_,i)local r=f.regions[i+1];if not r then return 0 end;return 1,true,r.s,r.e,r.name,r.id,0 end,
  GetSetProjectInfo_String=function(_,key)local i=tonumber(key:match(':(%d+)'));return true,f.regions[i+1].key end,
  AddProjectMarker2=function(_,_,s,e,name)serial=serial+1;f.regions[#f.regions+1]={id=serial,key='r'..serial,s=s,e=e,name=name};return serial end,
  SetProjectMarker3=function(_,id,_,s,e,name)for _,r in ipairs(f.regions)do if r.id==id then r.s=s;r.e=e;r.name=name;return true end end;return false end,
  ColorToNative=function()return 0 end,
  GetUserInputs=function()return true,f.answer end,
 }
 local M={tracks=function()return {'kick','snare'}end,get=function(k)if k=='active' then return f.active_set end;return f.state[k]or''end,put=function(k,v)f.state[k]=v end,
  stopped=function()assert(not f.recording,'Recording')end,
  edit=function(_,fn)assert(not f.recording);f.edits=f.edits+1;fn()end}
 local S=dofile(root..'/Scripts/solo_sections.lua')(M)
 gfx={mouse_x=0,mouse_y=0}
 for _,fn in ipairs({'rect','line'})do gfx[fn]=function(...)f.draws[#f.draws+1]={kind=fn,args={...}}end end
 local ui={tempo_menu=function()f.action='tempo'end,colors={muted={},text={},line={},blue={},record={},gold={}},text=function(label)f.labels[#f.labels+1]=label end,color=function()end,
  button=function(label,_,_,_,_,fn,_,enabled)if enabled~=false then f.buttons[label]=fn end end,
  comp_edges=function()return f.edges or {}end,
  comp_edge_plan=function(key,pos,signature)
   assert(not f.stale and (not signature or signature=='native-state'),'Comp changed')
   return {key=key,original=8,pos=pos or 8,low=6,high=10,signature='native-state',changes={}}
  end,
  move_comp_edge=function(key,pos,signature)assert(signature=='native-state');f.comp_edit={key=key,pos=pos}end,
  comp=function()return f.comp end,listen_mode=function()return f.mode or 'comp'end,target=function()return f.target end,
  rows=function()return f.takes end,chosen=function()return f.chosen end,
  selected=function(key)return f.selected and f.selected[key] or f.chosen and f.chosen.key==key end,
  selection_count=function()return f.selected_count or (f.chosen and 1 or 0)end,
  select=function(row,clip,position)f.chosen=row;f.clip=clip;f.position=position end,take_action=function(action)f.action=action end,
  changed=function(message)f.message=message end,
  run=function(fn)local ok,err=pcall(fn);if not ok then f.errors[#f.errors+1]=err end end}
 local V=dofile(root..'/Scripts/solo_timeline.lua')(M,S,ui)
 f.S,f.V=S,V
 function f.draw()f.buttons={};f.draws={};f.labels={};V.draw(24,215,1152,476,f.recording)end
 function f.mouse(t,down,pressed,y,start,finish)
  start,finish=start or 0,finish or 36
  gfx.mouse_x=212+(t-start)/(finish-start)*964;gfx.mouse_y=y or 365
  V.mouse(down,pressed or false,f.recording)
 end
 function f.label(value)for _,label in ipairs(f.labels)do if label==value then return true end end;return false end
 f.draw();return f
end
local f=fixture()
f.mouse(2,true,true);f.mouse(10,true)
check(#f.regions==0,'Dragging previews without modifying the song')
f.mouse(10,false)
check(#f.regions==1 and f.regions[1].s==2 and f.regions[1].e==10 and f.edits==1,'Forward drag creates exact snapped section in one edit')
check(f.S.mode()=='section','New section becomes recording target')
f=fixture();f.mouse(12,true,true);f.mouse(4,false)
check(f.regions[1].s==4 and f.regions[1].e==12,'Backward drag creates the same ordered range')
f=fixture();f.mouse(2,true,true);f.mouse(8,true);f.V.cancel();f.mouse(8,false)
check(#f.regions==0,'Escape cancels a preview without editing regions')
f=fixture();f.mouse(2,true,true);f.project='b';f.mouse(8,false)
check(#f.regions==0,'Changing project cancels an in-progress drag')
f=fixture();f.mouse(2,true,true);f.recording=true;f.mouse(8,false)
check(#f.regions==0,'Starting recording cancels an in-progress drag')
f=fixture();f.mouse(2,true,true);f.mouse(2,false)
check(#f.regions==0,'An empty-space click never makes a zero-length section')
f=fixture();local a=f.S.create(0,8,'Verse');local b=f.S.create(8,16,'Chorus');f.draw()
f.mouse(8,true,true);f.mouse(10,false)
check(f.S.find(a.key).e==10 and f.S.find(b.key).s==10,'Dragging a shared edge adjusts both neighboring sections')
f.draw();f.mouse(10,true,true);f.mouse(18,false)
check(f.S.find(a.key).e==10 and f.S.find(b.key).s==10 and #f.errors==1,'Crossing the neighboring section end is rejected without edits')
f=fixture();a=f.S.create(2,10,'Verse');f.draw();f.mouse(6,true,true);f.mouse(16,false)
check(f.S.find(a.key).s==12 and f.S.find(a.key).e==20,'Dragging the center moves the block without changing its duration')
f=fixture();a=f.S.create(2,10,'Verse');f.draw();f.mouse(6,true,true);f.mouse(6,false)
check(f.S.active().key==a.key and f.cursor==2,'Clicking a block selects it for recording')
f=fixture();f.S.set_snap(false);f.mouse(2.25,true,true);f.mouse(5.75,false)
check(math.abs(f.regions[1].s-2.25)<1e-8 and math.abs(f.regions[1].e-5.75)<1e-8,'Snap off preserves exact dragged times')
f=fixture();f.answer='Verse,9,8';f.V.new_section()
check(f.regions[1].s==16 and f.regions[1].e==32,'Numeric creation: bar 9 plus 8 bars ends at bar 17')
check(f.S.parse_position('9.2.00')==16.5 and not pcall(f.S.parse_position,'nonsense'),'Explicit bar-and-beat input is parsed and invalid text rejected')
f=fixture();f.mouse(4,true,true);f.S.create(20,24,'External edit');f.mouse(8,false)
check(#f.regions==1 and #f.errors==1,'External region changes invalidate a pending gesture')
f=fixture();a=f.S.create(0,8,'Verse');b=f.S.create(12,16,'Chorus');f.draw()
f.mouse(10,true,true);f.mouse(20,false)
check(#f.regions==3 and f.S.active().s==10 and f.S.active().e==12,'Drawing through a neighboring section stops at the available gap')
local function take(key,s,e)
 return {key=key,lane=0,name=key,items={{s=s,e=e}},note='',favorite=false,playing=false}
end
f=fixture();f.S.create(0,8,'Verse');f.S.create(8,16,'Chorus');f.S.select(f.S.list()[1].key)
f.takes={take('Short pass',2,6),take('Later pass',12,14)};f.draw()
check(f.buttons.Take==nil,'Take actions disabled until a take is chosen')
f.mouse(4,true,true,463)
check(f.chosen==f.takes[1] and not f.action and f.S.active().s==0,'Clicking a partial take selects without auditioning or changing section')
f.draw();f.buttons['Delete take']()
check(f.action=='delete','Timeline delete control routes to the selected take')
local aligned=false
for _,shape in ipairs(f.draws)do local a=shape.args
 if shape.kind=='rect' and a[2]==453 and a[4]==34 then
  aligned=math.abs(a[1]-(212+2/36*964))<1e-7 and math.abs(a[3]-4/36*964)<1e-7
 end
end
check(aligned,'Take start and duration use the same ruler coordinates as song sections')
f.mouse(13,true,true,509)
check(f.chosen==f.takes[2],'Takes outside the selected section remain visible and selectable')
f.takes[2].items={{s=8,e=10},{s=12,e=14}};f.draw()
local clips=0
for _,shape in ipairs(f.draws)do if shape.kind=='rect' and shape.args[2]==499 and shape.args[4]==34 and shape.args[5]==1 then clips=clips+1 end end
check(clips==2,'Split takes draw separate clips with their real gap')
f=fixture();for i=1,9 do f.takes[i]=take('Take '..i,0,8)end;f.draw()
f.mouse(2,false,false,463);f.V.wheel(-1);f.draw();f.mouse(2,true,true,463)
check(f.chosen==f.takes[2],'Wheel over lanes scrolls takes instead of panning the song')
f.active_set='guitar';f.chosen=nil;f.takes={take('Guitar',4,8)};f.draw();f.mouse(5,true,true,463)
check(f.chosen==f.takes[1],'Switching instruments resets lane scroll and displays only that set')
f.recording=true;f.draw();f.chosen=nil;f.mouse(5,true,true,463)
check(f.chosen==nil and f.buttons['Delete take']==nil,'Recording locks take selection and deletion')
f=fixture();f.takes={take('Outside',40,44)};f.draw()
local outside=false
for _,shape in ipairs(f.draws)do if shape.kind=='rect' and shape.args[4]==34 then outside=true end end
check(not outside,'Clips outside the visible time range are clipped from the drawing')
f=fixture();f.takes={take('First',0,8),take('Second',8,16)}
f.chosen=f.takes[2];f.selected={First=true,Second=true};f.selected_count=2;f.draw()
local outlines=0
for _,shape in ipairs(f.draws)do if shape.kind=='rect'and shape.args[4]==34 and shape.args[5]==0 then outlines=outlines+1 end end
check(outlines==2,'Timeline highlights every selected take')
check(f.buttons.Take==nil and f.buttons['Use in comp']==nil and f.buttons['Delete 2 takes']~=nil,'Timeline exposes batch Delete and disables single-take actions for multiple selection')
f.buttons['Delete 2 takes']();check(f.action=='delete','Timeline batch delete routes through the shared selection action')
check(f.buttons.Comp==nil,'Empty comp cannot be played')
f.comp=take('Comp',0,8);reaper.GetSetMediaItemInfo_String=function()return true,'First'end;f.draw()
check(f.buttons.Comp~=nil,'Saved comp has a dedicated playback control')
f.mouse(2,true,true,417);check(f.action=='listen_comp','Clicking the pinned comp lane activates saved comp')
f.selected_count=1;f.selected=nil;f.chosen=f.takes[1];f.target={s=2,e=6};f.mode='take';f.draw()
check(f.buttons.Comp and f.buttons.Take and f.buttons['Use in comp'],'Comp and Take toggles coexist with the passage commit action')
f.buttons.Take();check(f.action=='listen_take','Take toggle activates the highlighted whole lane')
f.buttons.Comp();check(f.action=='listen_comp','Comp toggle activates saved choices')
check(not f.buttons.Preview and not f.buttons['Back to comp']and not f.buttons['Play comp'],'Obsolete preview and return buttons are absent')
gfx.mouse_x=60;gfx.mouse_y=424
check(not f.V.mouse(true,true,false),'Comp header clicks reach the toggle buttons instead of the comp clip hit area')
f.mouse(3,true,true,463)
check(f.clip.s==0 and f.clip.e==8 and math.abs(f.position-3)<1e-8,'Clip selection passes exact clip and clicked musical position')
f.comp=nil;f.takes[1].items[1].deleted=true;f.takes[2].items[1].deleted=true
check(pcall(f.draw),'A native deletion between refreshes cannot crash timeline drawing')
f=fixture();f.takes={take('Slower',0,8)};f.takes[1].tempo={label='100 BPM',different=true,clips={[f.takes[1].items[1]]='100 BPM'}};f.draw()
local label=false;for _,s in ipairs(f.labels)do if s=='100 BPM / different'then label=true end end
check(label and f.buttons['Tempo...']~=nil,'Timeline exposes the tempo menu and displays a known mismatch')
local function comp_fixture()
 local f=fixture();f.comp=take('Comp',0,16);f.edges={{key='join',pos=8}};reaper.GetSetMediaItemInfo_String=function()return true,'Source'end;f.draw();return f
end
f=comp_fixture();f.mouse(8,true,true,417);f.mouse(9.125,true,false,417)
check(not f.comp_edit and #f.regions==0,'Dragging a Comp edge previews without changing audio or song regions')
check(pcall(f.draw),'Comp-edge preview draws without section-drag assumptions')
f.mouse(9.125,false,false,417)
check(f.comp_edit and math.abs(f.comp_edit.pos-9.125)<1e-8 and #f.regions==0,'Releasing a Comp edge preserves precise unsnapped timing and edits only the comp')
f=comp_fixture();f.mouse(8,true,true,417);f.mouse(18,false,false,417)
check(f.comp_edit and f.comp_edit.pos==10,'Comp-edge dragging clamps at the available microphone handles')
f=comp_fixture();f.mouse(8,true,true,417);f.mouse(9,true,false,417);f.V.cancel();f.mouse(9,false,false,417)
check(not f.comp_edit,'Escape cancels a comp-edge preview without an audio edit')
f=comp_fixture();f.mouse(8,true,true,417);f.stale=true;f.mouse(9,false,false,417)
check(not f.comp_edit and #f.errors==1,'A changed comp invalidates an in-progress edge drag')
f=comp_fixture();f.mouse(8,true,true,417);f.active_set='vocals';f.mouse(9,false,false,417)
check(not f.comp_edit,'Changing instruments cancels a comp-edge drag')
f=comp_fixture();f.mouse(8,true,true,417);f.recording=true;f.mouse(9,false,false,417)
check(not f.comp_edit,'Recording cancels pending comp-edge changes')
f=fixture()
check(not f.buttons['Zoom start']and not f.buttons['Zoom end'],'Boundary buttons require a selected passage or section')
a=f.S.create(8,16,'Verse');f.S.select(a.key);f.draw();local edits,cursor=f.edits,f.cursor
f.buttons['Zoom start']();f.draw()
check(f.label('Close-up / 0:06.00 - 0:10.00')and f.buttons.Back,'Zoom start shows one musical bar on either side of the section start')
check(f.edits==edits and f.cursor==cursor and not f.action,'Boundary zoom does not edit media, seek, or change playback')
check(f.label('4.2')and f.label('5.4'),'Close-up ruler labels individual beats on both sides of the boundary')
f.buttons['Zoom end']();f.draw()
check(f.label('Close-up / 0:14.00 - 0:18.00'),'Zoom end switches directly to the other boundary')
f.buttons.Back();f.draw()
check(f.label('Bars / 0:00.00 - 0:36.00')and f.buttons['Fit song'],'Back restores the original wide view after switching boundaries')
f.target={s=10,e=12};f.buttons['Zoom start']();f.draw()
check(f.label('Close-up / 0:08.00 - 0:12.00'),'A specifically selected take passage takes priority over a different song section')
check(f.V.cancel(),'Escape returns from close-up before closing the panel');f.draw()
check(f.label('Bars / 0:00.00 - 0:36.00')and not f.V.cancel(),'Returning from close-up clears its Escape handler')
f=comp_fixture();f.mouse(8,true,true,417);f.mouse(8,false,false,417);f.clock=0.15;f.mouse(8,true,true,417);f.draw()
check(f.label('Close-up / 0:06.00 - 0:10.00')and not f.comp_edit,'Double-clicking a comp join focuses its actual boundary without an edit')
f.mouse(8,false,false,417,6,10);f.mouse(8,true,true,417,6,10);f.mouse(8.125,false,false,417,6,10)
check(f.comp_edit and math.abs(f.comp_edit.pos-8.125)<1e-8,'Dragging after close-up applies the small intended offset without a jump')
f.V.history_changed();f.draw()
check(f.label('Close-up / 0:06.00 - 0:10.00'),'Native history refresh preserves the boundary close-up range')
f.comp_edit=nil;f.mouse(8,true,true,417,6,10);f.mouse(8.25,true,false,417,6,10)
check(f.V.cancel_drag(),'History can cancel an uncommitted comp-boundary gesture');f.mouse(8.25,false,false,417,6,10);f.draw()
check(not f.comp_edit and f.label('Close-up / 0:06.00 - 0:10.00'),'Cancelling for Undo keeps the zoom and cannot commit the old drag')
f=comp_fixture();f.mouse(8,true,true,417);f.mouse(8,false,false,417);f.clock=0.6;f.mouse(8,true,true,417);f.draw()
check(not f.buttons.Back,'Two separate slow clicks do not enter boundary zoom')
f=fixture();a=f.S.create(8,16,'Verse');f.draw();f.mouse(8,true,true);f.mouse(8,false);f.clock=0.1;f.mouse(8,true,true);f.draw()
check(f.label('Close-up / 0:06.00 - 0:10.00'),'Section handles support the same double-click close-up')
f=fixture();a=f.S.create(0,8,'Intro');f.S.select(a.key);f.draw();f.buttons['Zoom start']();f.draw()
check(f.label('Close-up / 0:00.00 - 0:02.00'),'Song-start close-up clamps at zero without inventing negative media')
f.buttons['+']();f.draw()
check(f.label('Close-up / 0:00.00 - 0:01.33'),'Further zoom stays anchored at the boundary even at project start')
for _=1,12 do f.buttons['+']();f.draw()end
check(f.label('Close-up / 0:00.00 - 0:00.04'),'Close-up supports sub-beat detail beyond the old two-second minimum')
f.V.reset();f.draw();check(f.label('Bars / 0:00.00 - 0:36.00')and not f.buttons.Back,'Project reset clears the old close-up and return range')
f=fixture();f.mouse(9,false,false,463);gfx.mouse_cap=16;f.V.wheel(1);f.draw()
check(f.label('Bars / 0:03.00 - 0:27.00'),'Option-wheel zooms at the mouse over a take lane instead of scrolling takes')
f=comp_fixture();f.mouse(8,true,true,417);gfx.mouse_cap=16;f.V.wheel(1);f.mouse(9,false,false,417)
check(math.abs(f.comp_edit.pos-9)<1e-8,'Wheel zoom cannot change the coordinate mapping during an active drag')
-- A different tempo and meter after bar 5: one bar each side must use the musical time map.
f=fixture();a=f.S.create(8,14,'Meter change');f.S.select(a.key)
reaper.TimeMap_GetMeasureInfo=function(_,m)if m<4 then return m*2,m*4,(m+1)*4,4,4,120 end;return 8+(m-4)*3,16+(m-4)*3,19+(m-4)*3,3,4,60 end
reaper.TimeMap2_timeToBeats=function(_,t)if t<8 then local m=math.floor(t/2);return (t-m*2)*2,m,4 end;local m=math.floor((t-8)/3);return t-8-m*3,m+4,3 end
reaper.TimeMap2_beatsToTime=function(_,b,m)return m<4 and m*2+b/2 or 8+(m-4)*3+b end
f.draw();f.buttons['Zoom start']();f.draw()
check(f.label('Close-up / 0:06.00 - 0:11.00'),'One-bar handles for zoom respect tempo and time-signature changes')
print(total..' visual timeline checks passed.')
