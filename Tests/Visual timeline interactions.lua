-- Run the real timeline and region modules with a synthetic 120 BPM project.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={regions={},state={},edits=0,project='a',cursor=0,recording=false,errors={},buttons={},takes={},draws={},labels={},active_set='drums'}
 local serial=0
 reaper={
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
  comp=function()return f.comp end,listen_mode=function()return f.mode or 'comp'end,target=function()return f.target end,
  rows=function()return f.takes end,chosen=function()return f.chosen end,
  selected=function(key)return f.selected and f.selected[key] or f.chosen and f.chosen.key==key end,
  selection_count=function()return f.selected_count or (f.chosen and 1 or 0)end,
  select=function(row,clip,position)f.chosen=row;f.clip=clip;f.position=position end,take_action=function(action)f.action=action end,
  changed=function(message)f.message=message end,
  run=function(fn)local ok,err=pcall(fn);if not ok then f.errors[#f.errors+1]=err end end}
 local V=dofile(root..'/Scripts/solo_timeline.lua')(M,S,ui)
 f.S,f.V=S,V
 function f.draw()f.buttons={};f.draws={};V.draw(24,215,1152,476,f.recording)end
 function f.mouse(t,down,pressed,y)
  gfx.mouse_x=212+t/36*964;gfx.mouse_y=y or 365
  V.mouse(down,pressed or false,f.recording)
 end
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
print(total..' visual timeline checks passed.')
