-- Run the real timeline and region modules with a synthetic 120 BPM project.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={regions={},state={},edits=0,project='a',cursor=0,recording=false,errors={},buttons={}}
 local serial=0
 reaper={
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
 local M={get=function(k)return f.state[k]or''end,put=function(k,v)f.state[k]=v end,
  stopped=function()assert(not f.recording,'Recording')end,
  edit=function(_,fn)assert(not f.recording);f.edits=f.edits+1;fn()end}
 local S=dofile(root..'/Scripts/solo_sections.lua')(M)
 gfx={mouse_x=0,mouse_y=0}
 for _,fn in ipairs({'rect','line'})do gfx[fn]=function()end end
 local ui={colors={muted={},text={},line={},blue={},record={},gold={}},text=function()end,color=function()end,
  button=function(label,_,_,_,_,fn,_,enabled)if enabled~=false then f.buttons[label]=fn end end,
  changed=function(message)f.message=message end,
  run=function(fn)local ok,err=pcall(fn);if not ok then f.errors[#f.errors+1]=err end end}
 local V=dofile(root..'/Scripts/solo_timeline.lua')(M,S,ui)
 f.S,f.V=S,V
 function f.draw()f.buttons={};V.draw(24,215,1152,430,f.recording)end
 function f.mouse(t,down,pressed,y)
  gfx.mouse_x=24+t/36*1152;gfx.mouse_y=y or 395
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
print(total..' visual timeline checks passed.')
