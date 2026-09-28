-- Runs the actual panel against a fake gfx surface, without controlling REAPER.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0
local function fixture()
  local f={project='song',recording=false,tempo_map=false,bpm=120,volume=0.5,calls={},clock=0,rows={}}
  local function call(kind,value) f.calls[#f.calls+1]={kind,value} end
  local M={ns='test',tracks=function()return {'track'}end,lanes=function()return f.rows end,
    audition=function(lane)call('audition',lane)end,
    delete_take=function(lane,key)call('delete',key);for i,row in ipairs(f.rows)do if row.key==key then table.remove(f.rows,i);break end end end,
    get=function(key)return key=='active' and 'scratch' or 'Scratch'end,
    sets=function()return {{id='scratch',name='Scratch'}}end,message=function(s)error(s)end}
  M.sections=function()return {recover_leadin=function()end,filter_takes=function(rows)return rows end,list=function()return {}end,
    mode=function()return ''end,active=function()return nil end,label=function()return 'Full song'end,
    looping=function()return false end,snapping=function()return true end}end
  local T={min_bpm=20,max_bpm=300,bpm=function()return f.bpm end,
    tempo_enabled=function()return not f.recording and not f.tempo_map end,
    set_bpm=function(v)f.bpm=v;call('tempo',v)end,
    click_db=function()return -12 end,volume_position=function()return f.volume end,
    position_db=function(v)return v==0 and -math.huge or v*60-60 end,
    format_db=function(v)return tostring(v)end,
    set_volume=function(v)f.volume=v;call('volume',v)end,
    set_click_db=function(v)call('db',v)end,sound_settings=function()call('sounds',true)end}
  local R={EnumProjects=function()return f.project end,
    time_precise=function()f.clock=f.clock+1;return f.clock end,
    GetExtState=function(_,key)return key=='panel_view' and 'review' or ''end,SetExtState=function()end,
    GetPlayState=function()return f.recording and 4 or 0 end,
    GetMediaTrackInfo_Value=function()return 0 end,
    GetToggleCommandStateEx=function()return 0 end,
    GetSet_LoopTimeRange2=function()return 0,0 end,
    atexit=function()end,defer=function(fn)f.frame=fn end}
  local g={mouse_x=0,mouse_y=0,mouse_cap=0,mouse_wheel=0}
  for _,key in ipairs({'set','setfont','rect','line','circle','drawstr','update'}) do g[key]=function()end end
  g.measurestr=function(s)return #s*8,16 end
  g.init=function(_,w,h)g.w=w;g.h=h end
  g.dock=function()return 0 end
  g.getchar=function()return f.key or 0 end
  local env=setmetatable({reaper=R,gfx=g,dofile=function(path)
    if path:match('solo_core.lua$') then return M end
    if path:match('solo_tempo.lua$') then return T end
    if path:match('solo_timeline.lua$') then return function()return {reset=function()end,cancel=function()return false end}end end
    error('Unexpected module '..path)
  end},{__index=_G})
  assert(loadfile(root..'/Scripts/Solo Studio - Open recording panel.lua','t',env))()
  function f.mouse(x,y,down)
    g.mouse_x=x;g.mouse_y=y;g.mouse_cap=down and 1 or 0
    f.frame()
  end
  return f
end
local function check(ok,name)assert(ok,name);passed=passed+1;print('PASS: '..name)end
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
local function take(key,lane,playing)return {key=key,lane=lane,name=key,note='',playing=playing,favorite=false}end
f=fixture();f.rows={take('Short take',0,false),take('Playing take',1,true)};f.frame()
f.mouse(400,435,true);f.mouse(400,435,false)
check(#f.calls==0,'Take-list click selects a partial take without switching audio')
f.mouse(620,388,true);f.mouse(620,388,false)
check(f.calls[1]and f.calls[1][1]=='audition'and f.calls[1][2]==0,'Audition button uses the explicitly selected take')
f.mouse(540,579,true);f.mouse(540,579,false)
check(f.calls[2]and f.calls[2][1]=='delete'and f.calls[2][2]=='Short take'and #f.rows==1,'Take-list Delete removes the selected take, not the playing one')
f=fixture();f.rows={take('Take 1',0,true)};f.recording=true;f.frame()
f.mouse(540,579,true);f.mouse(540,579,false)
check(#f.calls==0 and #f.rows==1,'Take-list deletion is disabled during recording')
f=fixture();f.rows={take('Old take',0,true)};f.frame();f.recording=true;f.frame()
f.rows={take('Old take',0,false),take('New take',1,true)};f.recording=false;f.frame()
f.mouse(540,579,true);f.mouse(540,579,false)
check(f.calls[1]and f.calls[1][2]=='New take','After Stop the new pass becomes the selected take for review or deletion')
print(passed..' panel interaction checks passed.')
