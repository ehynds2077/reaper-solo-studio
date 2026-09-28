-- Native gfx song editor. Drag previews are local; release commits one region edit.
local R=reaper
return function(M,S,ui)
 local V={};local C=ui.colors;local text,button,color=ui.text,ui.button,ui.color
 local view_start,view_end=0,nil
 local box,gesture,regions
 local palette={{0.29,0.48,0.63},{0.37,0.51,0.42},{0.56,0.43,0.29},{0.48,0.40,0.58},{0.30,0.51,0.53}}
 local function fmt(t)return R.format_timestr_pos(t,'',2)end
 local function duration(a,b)return string.format('%.2f bars',S.bar_position(b)-S.bar_position(a)):gsub('%.00 bars',' bars')end
 local function seconds(t)return string.format('%d:%05.2f',math.floor(t/60),t%60)end
 local function sig()
  local out={};for _,r in ipairs(S.list())do out[#out+1]=r.key..':'..r.s..':'..r.e..':'..r.name end
  return table.concat(out,'|')
 end
 function V.reset()view_start=0;view_end=nil;gesture=nil;box=nil end
 function V.cancel()local had=gesture~=nil;gesture=nil;return had end
 function V.fit()
  local minimum=R.TimeMap_GetMeasureInfo(0,16)
  local last=math.max(R.GetProjectLength(0),minimum)
  for _,r in ipairs(S.list())do last=math.max(last,r.e)end
  local _,measure=R.TimeMap2_timeToBeats(0,last)
  view_start=0;view_end=R.TimeMap_GetMeasureInfo(0,measure+2)
 end
 local function zoom(factor)
  local center=(view_start+view_end)/2;local span=math.max(2,(view_end-view_start)*factor)
  view_start=math.max(0,center-span/2);view_end=view_start+span
 end
 local function pan(fraction)
  local span=view_end-view_start;view_start=math.max(0,view_start+span*fraction);view_end=view_start+span
 end
 local function to_x(t)return box.x+(t-view_start)/(view_end-view_start)*box.w end
 local function to_time(x)return view_start+math.max(0,math.min(1,(x-box.x)/box.w))*(view_end-view_start)end
 local function selected()return assert(S.active(),'Click a section in the timeline first.')end
 local function ask_name()
  local row=selected();local ok,value=R.GetUserInputs('Section name',1,'Name:,extrawidth=180',row.name)
  if ok then S.rename(row.key,value)end
 end
 local function ask_edge(edge)
  local row=selected();local ok,value=R.GetUserInputs(edge=='s' and 'Section start' or 'Section end',1,'Bar or bar.beat.hundredths:,extrawidth=180',fmt(row[edge]))
  if ok then S.edge(row.key,edge,S.parse_position(value));ui.changed('Section boundary updated.')end
 end
 local function ask_length()
  local row=selected();local n=math.max(1,math.floor(S.bar_position(row.e)-S.bar_position(row.s)+0.5))
  local ok,value=R.GetUserInputs('Section length',1,'Length in whole bars:,extrawidth=180',tostring(n))
  if ok then S.edge(row.key,'e',S.end_after_bars(row.s,value));ui.changed('Section length updated.')end
 end
 function V.new_section()
  local start=math.max(0,S.snap(R.GetCursorPosition()))
  for _,row in ipairs(S.list())do if start>=row.s-0.00001 and start<row.e then start=row.e end end
  local ok,value=R.GetUserInputs('New section',3,'Name:,Start bar (or bar.beat):,Length in whole bars:,extrawidth=180','Verse,'..fmt(start)..',8')
  if not ok then return end
  local label,a,n=value:match('^([^,]*),([^,]*),([^,]*)$')
  assert(label,'Enter a name, start, and length.');local s=S.parse_position(a)
  local row=S.create(s,S.end_after_bars(s,n),label);S.select(row.key)
  if row.s<view_start or row.e>view_end then V.fit()end
  ui.changed('Section added. Drag its edges or click Start, End, or Length below.')
 end
 local function inside(x,y)return box and x>=box.x and x<=box.x+box.w and y>=box.y and y<=box.y+box.h end
 local function hit(x)
  -- Give visible boundary handles priority over section bodies.
  local best,edge,distance=nil,nil,9
  for _,row in ipairs(regions)do for _,e in ipairs({'s','e'})do
   local px=to_x(row[e]);local d=math.abs(x-px)
   if px>=box.x and px<=box.x+box.w and d<distance then best=row;edge=e;distance=d end
  end end
  if best then return best,edge end
  local t=to_time(x)
  for _,row in ipairs(regions)do if t>=row.s and t<row.e then return row,'move'end end
 end
 local function preview(g,x)
  local t=to_time(x);local a,b=g.s,g.e;local changes
  if g.kind=='new'then
   local p=math.max(g.low,math.min(g.high,S.snap(t)))
   a=math.min(g.anchor,p);b=math.max(g.anchor,p)
  elseif g.kind=='move'then
   a=math.max(0,S.snap(g.s+t-g.anchor));b=a+g.e-g.s
  else
   local p=math.max(0,S.snap(t));if g.kind=='s'then a=p else b=p end
   local ok,result=pcall(S.edge_plan,g.row.key,g.kind,p)
   if not ok then return a,b,nil,false end;changes=result
  end
  local valid=b-a>=0.001
  if not changes then for _,row in ipairs(regions)do
   if (not g.row or row.key~=g.row.key)and a<row.e-0.00001 and b>row.s+0.00001 then valid=false end
  end end
  return a,b,changes,valid
 end
 function V.mouse(down,pressed,recording)
  if recording then gesture=nil;return inside(gfx.mouse_x,gfx.mouse_y)end
  if gesture then
   local g=gesture
   if g.project~=R.EnumProjects(-1,'')then gesture=nil;return true end
   g.moved=g.moved or math.abs(gfx.mouse_x-g.x)>3
   g.a,g.b,g.changes,g.valid=preview(g,gfx.mouse_x)
   if not down then
    gesture=nil
    ui.run(function()
     assert(g.signature==sig(),'Sections changed while dragging. Try the edit again.')
     if not g.moved then if g.row then S.select(g.row.key);ui.changed('Selected '..g.row.name..' for recording.')end;return end
     assert(g.valid,'That range is empty or overlaps another section. Drag within the open space, or use Split at cursor.')
     if g.kind=='new'then
      local row=S.create(g.a,g.b,'Section '..(#regions+1));S.select(row.key)
      ui.changed('Section added. Click its name below to rename it.')
     elseif g.kind=='move'then S.resize(g.row.key,g.a,g.b);S.select(g.row.key);ui.changed('Section moved.')
     else S.edge(g.row.key,g.kind,g.kind=='s' and g.a or g.b);S.select(g.row.key);ui.changed('Section boundary updated.')end
    end)
   end
   return true
  end
  if not pressed or not inside(gfx.mouse_x,gfx.mouse_y)then return false end
  if gfx.mouse_y<box.y+32 then
   ui.run(function()R.SetEditCurPos2(0,math.max(0,S.snap(to_time(gfx.mouse_x))),true,R.GetPlayState()&1~=0)end)
   return true
  end
  local row,kind=hit(gfx.mouse_x);local t=to_time(gfx.mouse_x)
  local low,high=0,math.huge
  if not row then for _,r in ipairs(regions)do if r.e<=t then low=math.max(low,r.e)elseif r.s>t then high=math.min(high,r.s)end end end
  local anchor=row and t or math.max(low,math.min(high,S.snap(t)))
  gesture={project=R.EnumProjects(-1,''),signature=sig(),row=row,kind=kind or 'new',x=gfx.mouse_x,anchor=anchor,
   s=row and row.s or anchor,e=row and row.e or anchor,low=low,high=high,moved=false,valid=true}
  gesture.a,gesture.b=gesture.s,gesture.e
  return true
 end
 function V.wheel(delta)
  if not inside(gfx.mouse_x,gfx.mouse_y)then return false end
  if not gesture then pan(delta>0 and -0.12 or 0.12)end
  return true
 end
 function V.draw(x,y,w,h,recording)
  if not view_end then V.fit()end
  regions=S.list();local active=S.active();local enabled=not recording
  text('Song timeline',x,y,4)
  text('Draw your arrangement here. Choose a block to record that section.',x+158,y+3,3,C.muted)
  button('New section...',x,y+36,142,34,V.new_section,C.blue,enabled)
  button('Split at cursor (B)',x+152,y+36,164,34,function()S.split();ui.changed('Section split. Click the new name below to rename it.')end,nil,enabled)
  button('Use scratch take',x+326,y+36,152,34,function()S.from_scratch();S.full_song();V.fit();ui.changed('Click the ruler at a transition, then Split at cursor. Or press B while listening.')end,nil,enabled and #regions==0)
  button(S.snapping()and'Snap: bars'or'Snap: off',x+488,y+36,112,34,function()S.set_snap(not S.snapping())end,nil,enabled)
  button('Fit song',x+w-288,y+36,90,34,V.fit)
  button('-',x+w-188,y+36,38,34,function()zoom(1.5)end)
  button('+',x+w-144,y+36,38,34,function()zoom(1/1.5)end)
  button('<',x+w-94,y+36,42,34,function()pan(-0.5)end)
  button('>',x+w-46,y+36,46,34,function()pan(0.5)end)
  text('Bars  /  '..seconds(view_start)..' - '..seconds(view_end),x,y+85,3,C.muted)
  text('Click ruler to position cursor',x+w-212,y+85,3,C.muted)
  box={x=x,y=y+108,w=w,h=154}
  color({0.12,0.14,0.17});gfx.rect(box.x,box.y,box.w,box.h,1)
  local _,first=R.TimeMap2_timeToBeats(0,view_start);local _,last=R.TimeMap2_timeToBeats(0,view_end)
  local step=math.max(1,math.ceil((last-first+1)*58/w))
  for bar=math.floor(first/step)*step,last+1,step do
   local px=to_x(R.TimeMap_GetMeasureInfo(0,bar))
   if px>=x and px<x+w then
    color(C.line);gfx.line(px,box.y+27,px,box.y+box.h)
    text(tostring(bar+1),px+5,box.y+5,3,C.muted)
   end
  end
  local g=gesture;local previews={}
  if g and g.moved then
   if g.changes then for _,c in ipairs(g.changes)do previews[c.row.key]={s=c.s,e=c.e}end
   elseif g.row then previews[g.row.key]={s=g.a,e=g.b}end
  end
  local function block(row,index,new)
   local p=previews[row.key]or row;local a=math.max(x,to_x(p.s));local b=math.min(x+w,to_x(p.e))
   if b<=a then return end
   local selected=active and active.key==row.key;local tint=palette[(index-1)%#palette+1]
   color(g and not g.valid and (new or g.row and g.row.key==row.key)and C.record or tint)
   gfx.rect(a+1,box.y+37,math.max(1,b-a-2),box.h-45,1)
   if selected or new then color(C.text);gfx.rect(a+1,box.y+37,math.max(1,b-a-2),box.h-45,0)end
   if b-a>55 then
    text(row.name,a+12,box.y+53,1,C.text,b-a-24)
    text(duration(p.s,p.e),a+12,box.y+82,3,C.text,b-a-24)
   end
   if b-a>22 then color(C.text);gfx.rect(a+5,box.y+66,2,21,1);gfx.rect(b-7,box.y+66,2,21,1)end
  end
  for i,row in ipairs(regions)do block(row,i)end
  if g and g.kind=='new' and g.moved then block({key='preview',s=g.a,e=g.b,name='New section'},#regions+1,true)end
  if #regions==0 and not(g and g.moved)then
   text('Drag from the start to the end of your first section',x+24,box.y+64,4,C.text)
   text('Or click New section... and enter a start bar and length.',x+24,box.y+99,1,C.muted)
  end
  local px=to_x(S.position());if px>=x and px<=x+w then color(C.gold);gfx.line(px,box.y,px,box.y+box.h);gfx.rect(px-3,box.y,6,7,1)end
  local help='Drag empty space: add section     Drag center: move     Drag edge: resize     Shared edge: adjust both sections'
  if g and g.moved then help=(g.valid and 'Preview: 'or'Invalid range: ')..fmt(g.a)..' to '..fmt(g.b)..'  /  '..duration(g.a,g.b)..'   |   Release to apply; Esc to cancel'end
  text(help,x,y+275,3,g and not g.valid and C.record or C.muted,w)
  local iy=y+310
  if active then
   text('Selected section',x,iy,3,C.muted)
   button(active.name..'  (rename)',x,iy+23,240,36,ask_name,nil,enabled)
   button('Start: '..fmt(active.s),x+250,iy+23,178,36,function()ask_edge('s')end,nil,enabled)
   button('End: '..fmt(active.e),x+438,iy+23,178,36,function()ask_edge('e')end,nil,enabled)
   button('Length: '..duration(active.s,active.e),x+626,iy+23,198,36,ask_length,nil,enabled)
   button('Remove label',x+w-142,iy+23,142,36,function()
    if R.ShowMessageBox('Remove "'..active.name..'"? Recorded audio stays in place.','Remove section label',4)==6 then S.remove(active.key)end
   end,nil,enabled)
   text('Positions are bar.beat.hundredths. Example: start 1, end 9 = 8 bars. Click any value to change it.',x,iy+70,3,C.muted,w)
  else
   text('For an exact length: New section...  >  name, start bar, length in bars.',x,iy+24,1,C.text,w)
   text('Example: Verse, start 9, length 8 creates a section from bar 9 to bar 17.',x,iy+56,3,C.muted,w)
  end
 end
 return V
end
