-- Runs the actual panel against a fake gfx surface, without controlling REAPER.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0
local function fixture()
  local f={project='song',recording=false,tempo_map=false,bpm=120,volume=0.5,calls={},clock=0,rows={},set='scratch',errors={},labels={}}
  local function call(kind,value) f.calls[#f.calls+1]={kind,value} end
  local M={ns='test',tracks=function()return {'track'}end,lanes=function()return f.rows end,
    audition=function(lane)call('audition',lane)end,
    delete_takes=function(rows)
      if f.delete_fail then error('Simulated failure')end
      local keys={};for _,row in ipairs(rows)do keys[#keys+1]=row.key end
      call('delete',table.concat(keys,','))
      for i=#f.rows,1,-1 do for _,key in ipairs(keys)do if f.rows[i].key==key then table.remove(f.rows,i);break end end end
    end,
    get=function(key)return key=='active' and f.set or 'Scratch'end,
    sets=function()return {{id='scratch',name='Scratch'}}end,message=function(s)f.errors[#f.errors+1]=s end}
  M.sections=function()return {recover_leadin=function()end,filter_takes=function(rows)if not f.filter then return rows end;local out={};for _,row in ipairs(rows)do if f.filter[row.key]then out[#out+1]=row end end;return out end,list=function()return {}end,
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
  g.drawstr=function(s)f.labels[#f.labels+1]=s end
  local env=setmetatable({reaper=R,gfx=g,dofile=function(path)
    if path:match('solo_core.lua$') then return M end
    if path:match('solo_tempo.lua$') then return T end
    if path:match('solo_timeline.lua$') then return function()return {reset=function()end,cancel=function()return false end}end end
    if path:match('solo_take_selection.lua$')then return dofile(path)end
    error('Unexpected module '..path)
  end},{__index=_G})
  assert(loadfile(root..'/Scripts/Solo Studio - Open recording panel.lua','t',env))()
  function f.mouse(x,y,down,mods)
    g.mouse_x=x;g.mouse_y=y;g.mouse_cap=(down and 1 or 0)|(mods or 0)
    f.frame()
  end
  function f.click(x,y,mods)f.mouse(x,y,true,mods);f.mouse(x,y,false,mods)end
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
f=fixture();f.rows={take('First',0,true),take('Middle',1),take('Last',2)};f.frame()
f.click(400,477);f.click(540,579);f.click(620,388)
check(f.calls[1][2]=='Middle'and f.calls[2][1]=='audition'and f.calls[2][2]==2,'Deleting a middle take selects its next neighbor, not the playing first take')
f.click(540,579);f.click(620,388)
check(f.calls[3][2]=='Last'and f.calls[4][2]==0,'Deleting the final take selects the previous surviving take')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,4);f.click(620,388)
check(#f.calls==0,'Audition disabled when several takes are selected')
f.click(540,579)
check(f.calls[1][2]=='First,Last'and #f.rows==1,'Cmd-click selects disjoint takes and Delete submits one batch')
f.click(620,388)
check(f.calls[2][2]==1,'After deleting disjoint takes, the nearest surviving neighbor is selected')
f=fixture();f.rows={take('First',0),take('Middle',1),take('Last',2)};f.frame()
f.click(400,435);f.click(400,519,8);f.click(540,579)
check(f.calls[1][2]=='First,Middle,Last'and #f.rows==0,'Shift-click selects an inclusive range for batch deletion')
f.click(540,579)
check(#f.calls==1,'Deleting every take leaves no selection or repeat deletion')
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
print(passed..' panel interaction checks passed.')
