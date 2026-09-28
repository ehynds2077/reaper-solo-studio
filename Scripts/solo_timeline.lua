-- Native gfx song editor. Drag previews are local; release commits one region edit.
local R=reaper
return function(M,S,ui)
 local V={};local C=ui.colors;local text,button,color=ui.text,ui.button,ui.color
 local view_start,view_end=0,nil
 local focus,wide_view,last_click
 local box,gesture,regions
 local take_box,comp_box,take_hits,take_scroll,take_visible=nil,nil,{},0,1
 local last_set,last_selected,record_start
 local comp_hits={}
 local lane_height=46
 local palette={{0.29,0.48,0.63},{0.37,0.51,0.42},{0.56,0.43,0.29},{0.48,0.40,0.58},{0.30,0.51,0.53}}
 local function fmt(t)return R.format_timestr_pos(t,'',2)end
 local function duration(a,b)return string.format('%.2f bars',S.bar_position(b)-S.bar_position(a)):gsub('%.00 bars',' bars')end
 local function seconds(t)return string.format('%d:%05.2f',math.floor(t/60),t%60)end
 local function sig()
  local out={};for _,r in ipairs(S.list())do out[#out+1]=r.key..':'..r.s..':'..r.e..':'..r.name end
  return table.concat(out,'|')
 end
 function V.reset()
  view_start=0;view_end=nil;gesture=nil;box=nil;take_box=nil;comp_box=nil;take_hits={};take_scroll=0
  last_set=nil;last_selected=nil;record_start=nil;comp_hits={}
  focus=nil;wide_view=nil;last_click=nil
 end
 local function back()
  if wide_view then view_start,view_end=wide_view.s,wide_view.e end
  focus=nil;wide_view=nil;last_click=nil
 end
 function V.cancel()
  if gesture then gesture=nil;last_click=nil;return true end
  if wide_view then back();return true end
  return false
 end
 function V.fit()
  focus=nil;wide_view=nil;last_click=nil
  local minimum=R.TimeMap_GetMeasureInfo(0,16)
  local last=math.max(R.GetProjectLength(0),minimum)
  for _,r in ipairs(S.list())do last=math.max(last,r.e)end
  local _,measure=R.TimeMap2_timeToBeats(0,last)
  view_start=0;view_end=R.TimeMap_GetMeasureInfo(0,measure+2)
 end
 local function zoom(factor,anchor)
  if gesture then return end
  anchor=anchor or (focus and focus.pos>=view_start and focus.pos<=view_end and focus.pos)or(view_start+view_end)/2
  local fraction=(anchor-view_start)/(view_end-view_start)
  local span=math.max(0.04,(view_end-view_start)*factor)
  view_start=math.max(0,anchor-span*fraction);view_end=view_start+span
 end
 local function pan(fraction)
  if gesture then return end
  local span=view_end-view_start;view_start=math.max(0,view_start+span*fraction);view_end=view_start+span
 end
 local function to_x(t)return box.x+(t-view_start)/(view_end-view_start)*box.w end
 local function to_time(x)return view_start+math.max(0,math.min(1,(x-box.x)/box.w))*(view_end-view_start)end
 -- Follow musical bars, including tempo and meter changes, rather than a fixed number of seconds.
 local function shift_bar(pos,offset)
  local beats,measure,count=R.TimeMap2_timeToBeats(0,pos);measure=measure+offset
  if measure<0 then return 0 end
  local _,_,_,numerator=R.TimeMap_GetMeasureInfo(0,measure)
  return R.TimeMap2_beatsToTime(0,beats/count*numerator,measure)
 end
 local function close_up(pos,key)
  if gesture then return end
  wide_view=wide_view or {s=view_start,e=view_end}
  focus={pos=pos,key=key}
  view_start=shift_bar(pos,-1);view_end=shift_bar(pos,1)
  last_click=nil
 end
 local function zoom_boundary(edge)
  local range=ui.target()or S.active()
  if range then close_up(range[edge])end
 end
 local function double_click(key)
  local now=R.time_precise()
  local previous=last_click;last_click=nil
  return previous and previous.key==key and previous.project==R.EnumProjects(-1,'') and previous.set==M.get('active')
   and now-previous.time<0.35 and math.abs(gfx.mouse_x-previous.x)<7 and math.abs(gfx.mouse_y-previous.y)<7
 end
 local function remember_click(key)
  last_click={key=key,time=R.time_precise(),x=gfx.mouse_x,y=gfx.mouse_y,project=R.EnumProjects(-1,''),set=M.get('active')}
 end
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
 local function contains(b,x,y)return b and x>=b.x and x<b.x+b.w and y>=b.y and y<b.y+b.h end
 local function inside(x,y)return contains(box,x,y)end
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
  if recording then gesture=nil;return inside(gfx.mouse_x,gfx.mouse_y) or contains(comp_box,gfx.mouse_x,gfx.mouse_y) or contains(take_box,gfx.mouse_x,gfx.mouse_y)end
  if pressed and not gesture and contains(comp_box,gfx.mouse_x,gfx.mouse_y)then
   -- Let the shared button handler receive the Comp / Take controls in the gutter.
   if gfx.mouse_x<box.x then return false end
   for _,edge in ipairs(comp_hits)do if math.abs(gfx.mouse_x-edge.x)<=7 then
    if double_click('comp:'..edge.key)then close_up(edge.pos,edge.key);return true end
    ui.run(function()
     if ui.listen_mode()~='comp'then ui.take_action('listen_comp')end
     local plan=ui.comp_edge_plan(edge.key)
     gesture={kind='comp_edge',key=edge.key,project=R.EnumProjects(-1,''),set=M.get('active'),x=gfx.mouse_x,
      original=plan.original,low=plan.low,high=plan.high,signature=plan.signature,plan=plan,valid=true,moved=false}
    end)
    return true
   end end
   if ui.comp() then ui.run(function()ui.take_action('listen_comp')end)end
   return true
  end
  if pressed and not gesture and contains(take_box,gfx.mouse_x,gfx.mouse_y)then
   for _,hit in ipairs(take_hits)do if contains(hit,gfx.mouse_x,gfx.mouse_y)then ui.select(hit.row,hit.clip,to_time(gfx.mouse_x));break end end
   return true
  end
  if gesture then
   local g=gesture
   if g.project~=R.EnumProjects(-1,'')then gesture=nil;return true end
   g.moved=g.moved or math.abs(gfx.mouse_x-g.x)>3
   if g.kind=='comp_edge'then
    if g.set~=M.get('active')then gesture=nil;return true end
    local pos=math.max(g.low,math.min(g.high,g.original+to_time(gfx.mouse_x)-to_time(g.x)))
    local ok,plan=pcall(ui.comp_edge_plan,g.key,pos,g.signature);g.valid=ok;g.plan=ok and plan or g.plan;g.error=not ok and tostring(plan)or nil
    if not down then
     gesture=nil
     ui.run(function()
      assert(g.valid,g.error)
      if g.moved then
       last_click=nil;ui.move_comp_edge(g.key,g.plan.pos,g.signature)
       if focus then focus.pos=g.plan.pos;focus.key=g.key end
       ui.changed('Comp boundary moved across the recording set. Song sections and source takes are unchanged.')
      else ui.take_action('listen_comp');remember_click('comp:'..g.key)end
     end)
    end
    return true
   end
   g.a,g.b,g.changes,g.valid=preview(g,gfx.mouse_x)
   if not down then
    gesture=nil
    ui.run(function()
     assert(g.signature==sig(),'Sections changed while dragging. Try the edit again.')
     if not g.moved then if g.row then
      S.select(g.row.key);ui.changed('Selected '..g.row.name..' for recording.')
      if g.kind=='s'or g.kind=='e'then remember_click('section:'..g.row.key..g.kind)end
     end;return end
     last_click=nil
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
  if gfx.mouse_y<box.y+24 then
   ui.run(function()R.SetEditCurPos2(0,math.max(0,S.snap(to_time(gfx.mouse_x))),true,R.GetPlayState()&1~=0)end)
   return true
  end
  local row,kind=hit(gfx.mouse_x);local t=to_time(gfx.mouse_x)
  if row and (kind=='s'or kind=='e')and double_click('section:'..row.key..kind)then close_up(row[kind]);return true end
  local low,high=0,math.huge
  if not row then for _,r in ipairs(regions)do if r.e<=t then low=math.max(low,r.e)elseif r.s>t then high=math.min(high,r.s)end end end
  local anchor=row and t or math.max(low,math.min(high,S.snap(t)))
  gesture={project=R.EnumProjects(-1,''),signature=sig(),row=row,kind=kind or 'new',x=gfx.mouse_x,anchor=anchor,
   s=row and row.s or anchor,e=row and row.e or anchor,low=low,high=high,moved=false,valid=true}
  gesture.a,gesture.b=gesture.s,gesture.e
  return true
 end
 function V.wheel(delta)
  if (gfx.mouse_cap or 0)&16~=0 and (inside(gfx.mouse_x,gfx.mouse_y)or contains(comp_box,gfx.mouse_x,gfx.mouse_y)or contains(take_box,gfx.mouse_x,gfx.mouse_y))then
   if gfx.mouse_x>=box.x then zoom(delta>0 and 1/1.5 or 1.5,to_time(gfx.mouse_x));return true end
  end
  if contains(take_box,gfx.mouse_x,gfx.mouse_y)then take_scroll=math.max(0,take_scroll-delta);return true end
  if not inside(gfx.mouse_x,gfx.mouse_y)then return false end
  if not gesture then pan(delta>0 and -0.12 or 0.12)end
  return true
 end
 local function take_name(row)return row.name:match('^%d+$')and 'Take '..row.name or row.name end
 local function spans(row)
  local result={};local start,finish=math.huge,0
  for _,item in ipairs(row.items)do
   if R.ValidatePtr2(0,item,'MediaItem*')then
   local a=R.GetMediaItemInfo_Value(item,'D_POSITION');local b=a+R.GetMediaItemInfo_Value(item,'D_LENGTH')
   start=math.min(start,a);finish=math.max(finish,b)
   if b>a then result[#result+1]={s=a,e=b,item=item}end
   end
  end
  return result,start==math.huge and 0 or start,finish
 end
 function V.draw(x,y,w,h,recording)
  if not view_end then V.fit()end
  regions=S.list();local active=S.active();local enabled=not recording
  local takes=ui.rows();local chosen=ui.chosen();local selected_count=ui.selection_count();local set=M.get('active')
  local comp=ui.comp();local listen_mode=ui.listen_mode();local target=ui.target()
  if set~=last_set then take_scroll=0;last_selected=nil;last_set=set;record_start=nil;last_click=nil end
  text('Song timeline',x,y,4)
  text('Click a section to record it. Double-click an edge to zoom in; drag to adjust.',x+158,y+3,3,C.muted,w-158)
  button('New section...',x,y+30,142,32,V.new_section,C.blue,enabled)
  button('Split at cursor (B)',x+152,y+30,164,32,function()S.split();ui.changed('Section split. Click the section name below to rename it.')end,nil,enabled)
  button('Use scratch take',x+326,y+30,152,32,function()S.from_scratch();S.full_song();V.fit();ui.changed('Click the ruler at a transition, then Split at cursor. Or press B while listening.')end,nil,enabled and #regions==0)
  button(S.snapping()and'Snap: bars'or'Snap: off',x+488,y+30,112,32,function()S.set_snap(not S.snapping())end,nil,enabled)
  button('Zoom start',x+610,y+30,104,32,function()zoom_boundary('s')end,nil,target~=nil or active~=nil)
  button('Zoom end',x+722,y+30,104,32,function()zoom_boundary('e')end,nil,target~=nil or active~=nil)
  button(wide_view and 'Back' or 'Fit song',x+w-288,y+30,90,32,wide_view and back or V.fit)
  button('-',x+w-188,y+30,38,32,function()zoom(1.5)end)
  button('+',x+w-144,y+30,38,32,function()zoom(1/1.5)end)
  button('<',x+w-94,y+30,42,32,function()pan(-0.5)end)
  button('>',x+w-46,y+30,46,32,function()pan(0.5)end)
  text((focus and 'Close-up / 'or'Bars / ')..seconds(view_start)..' - '..seconds(view_end),x,y+74,3,focus and C.gold or C.muted,305)
  text('Alt/Option + wheel: zoom at mouse / Wheel: scroll',x+315,y+74,3,C.muted,w-565)
  button('Tempo...',x+w-236,y+69,108,25,ui.tempo_menu,nil,enabled and #takes>0)
  button('Up',x+w-118,y+69,50,25,function()take_scroll=math.max(0,take_scroll-1)end)
  button('Down',x+w-62,y+69,62,25,function()take_scroll=take_scroll+1 end)
  local gutter=188
  box={x=x+gutter,y=y+99,w=w-gutter,h=88}
  comp_box={x=x,y=box.y+box.h,w=w,h=lane_height}
  take_box={x=x,y=comp_box.y+comp_box.h,w=w,h=math.max(lane_height,y+h-102-(comp_box.y+comp_box.h))}
  take_hits={};take_visible=math.max(1,math.floor(take_box.h/lane_height))
  local count=#takes+(recording and 1 or 0)
  local selected_index
  for i,row in ipairs(takes)do if chosen and row.key==chosen.key then selected_index=i end end
  if chosen and chosen.key~=last_selected and selected_index then
   if selected_index<=take_scroll then take_scroll=selected_index-1
   elseif selected_index>take_scroll+take_visible then take_scroll=selected_index-take_visible end
  end
  last_selected=chosen and chosen.key
  if recording and not record_start then
   record_start=S.mode()=='section' and active and active.s or R.GetCursorPosition()
   take_scroll=math.max(0,count-take_visible)
  elseif not recording then record_start=nil end
  take_scroll=math.max(0,math.min(take_scroll,count-take_visible))
  color({0.12,0.14,0.17});gfx.rect(x,box.y,w,box.h+comp_box.h+take_box.h,1)
  text(M.get('set.'..set..'.name')~='' and M.get('set.'..set..'.name')or 'Choose an instrument',x+8,box.y+4,1,C.text,gutter-16)
  text(#takes..' takes / '..#M.tracks()..' tracks',x+8,box.y+27,3,C.muted,gutter-16)
  text('Song sections',x+8,box.y+60,3,C.muted,gutter-16)
  local _,first=R.TimeMap2_timeToBeats(0,view_start);local _,last=R.TimeMap2_timeToBeats(0,view_end)
  local step=math.max(1,math.ceil((last-first+1)*58/box.w))
  local ticks={}
  for bar=math.floor(first/step)*step,last+1,step do
   local start,_,_,beats=R.TimeMap_GetMeasureInfo(0,bar)
   local px=to_x(start)
   if px>=box.x and px<box.x+box.w then
    ticks[#ticks+1]=px
    color(C.line);gfx.line(px,box.y+24,px,box.y+box.h)
    text(tostring(bar+1),px+5,box.y+4,3,C.muted)
   end
   if step==1 then
    local width=to_x(R.TimeMap_GetMeasureInfo(0,bar+1))-px
    if width/beats>=36 then for beat=0,beats-1 do
     local bx=to_x(R.TimeMap2_beatsToTime(0,beat,bar))
     if beat>0 and bx>=box.x and bx<box.x+box.w then
      ticks[#ticks+1]=bx;color(C.line);gfx.line(bx,box.y+18,bx,box.y+box.h)
      text(tostring(bar+1)..'.'..(beat+1),bx+4,box.y+4,3,C.muted)
     end
     local subdivisions=width/beats>=160 and 4 or width/beats>=80 and 2 or 1
     for sub=1,subdivisions-1 do
      local sx=to_x(R.TimeMap2_beatsToTime(0,beat+sub/subdivisions,bar))
      if sx>=box.x and sx<box.x+box.w then color(C.line);gfx.line(sx,box.y+20,sx,box.y+27)end
     end
    end end
   end
  end
  local g=gesture;local previews={}
  if g and g.moved and g.kind~='comp_edge'then
   if g.changes then for _,c in ipairs(g.changes)do previews[c.row.key]={s=c.s,e=c.e}end
   elseif g.row then previews[g.row.key]={s=g.a,e=g.b}end
  end
  local function block(row,index,new)
   local p=previews[row.key]or row;local a=math.max(box.x,to_x(p.s));local b=math.min(box.x+box.w,to_x(p.e))
   if b<=a then return end
   local selected=active and active.key==row.key;local tint=palette[(index-1)%#palette+1]
   color(g and not g.valid and (new or g.row and g.row.key==row.key)and C.record or tint)
   gfx.rect(a+1,box.y+30,math.max(1,b-a-2),52,1)
   if selected or new then color(C.text);gfx.rect(a+1,box.y+30,math.max(1,b-a-2),52,0)end
   if b-a>55 then
    text(row.name,a+12,box.y+35,1,C.text,b-a-24)
    text(duration(p.s,p.e),a+12,box.y+60,3,C.text,b-a-24)
   end
   if b-a>22 then
    color(C.text)
    if p.s>=view_start then gfx.rect(a+5,box.y+44,2,21,1)end
    if p.e<=view_end then gfx.rect(b-7,box.y+44,2,21,1)end
   end
  end
  for i,row in ipairs(regions)do block(row,i)end
  if g and g.kind=='new' and g.moved then block({key='preview',s=g.a,e=g.b,name='New section'},#regions+1,true)end
  if #regions==0 and not(g and g.moved)then
   text('Drag here to create a section, or use New section... for an exact length.',box.x+16,box.y+49,1,C.muted,box.w-32)
  end
  local cy=comp_box.y
  color({0.19,0.26,0.24});gfx.rect(x,cy,w,lane_height-2,1)
  text('Comp',x+12,cy+2,1,C.text,gutter-20)
  button('Comp',x+8,cy+22,80,21,function()ui.take_action('listen_comp')end,listen_mode=='comp'and C.blue or nil,enabled and comp~=nil)
  button('Take',x+96,cy+22,80,21,function()ui.take_action('listen_take')end,listen_mode=='take'and C.blue or nil,enabled and selected_count==1)
  for _,px in ipairs(ticks)do color(C.line);gfx.line(px,cy,px,cy+lane_height-2)end
  local function comp_clip(a,b,label,tint)
   local left=math.max(box.x,to_x(a));local right=math.min(box.x+box.w,to_x(b))
   if right>left then
    color(tint);gfx.rect(left,cy+5,right-left,34,1)
    color(C.text);gfx.rect(left,cy+5,right-left,34,0)
    if right-left>45 then text(label,left+8,cy+14,3,C.text,right-left-16)end
   end
  end
  comp_hits={}
  if comp then
   local changed={}
   if g and g.kind=='comp_edge'and g.plan then for _,change in ipairs(g.plan.changes)do changed[change.clip.item]=change end end
   for _,clip in ipairs(spans(comp))do
    local p=changed[clip.item];if p then clip.s=p.s;clip.e=p.e end
    local _,name=R.GetSetMediaItemInfo_String(clip.item,'P_EXT:SoloStudioSourceName','',false)
    comp_clip(clip.s,clip.e,name~='' and ('Take '..name):gsub('^Take (%D)','%1') or 'Kept passage',{0.28,0.43,0.36})
   end
   if ui.comp_edges then for _,edge in ipairs(ui.comp_edges())do
    local pos=g and g.kind=='comp_edge'and g.key==edge.key and g.plan.pos or edge.pos
    local px=to_x(pos)
    if px>=box.x and px<=box.x+box.w then
     comp_hits[#comp_hits+1]={x=px,key=edge.key,pos=pos}
     color(g and g.kind=='comp_edge'and g.key==edge.key and C.gold or C.text)
     gfx.rect(px-2,cy+9,4,26,1)
    end
   end end
   if g and g.kind=='comp_edge'then
    local a=math.max(box.x,to_x(g.low));local b=math.min(box.x+box.w,to_x(g.high))
    color(C.gold);gfx.line(a,cy+41,b,cy+41);gfx.line(a,cy+36,a,cy+43);gfx.line(b,cy+36,b,cy+43)
   end
  else text('Click a take clip below, then Use in comp.',box.x+16,cy+14,3,C.muted,box.w-32)end
  for i=take_scroll+1,math.min(count,take_scroll+take_visible)do
   local row=takes[i];local live=not row;local ry=take_box.y+(i-take_scroll-1)*lane_height
   local is_selected=row and ui.selected(row.key)
   color(is_selected and {0.22,0.31,0.38}or {0.16,0.19,0.23});gfx.rect(x,ry,w,lane_height-2,1)
   if active then
    local a=math.max(box.x,to_x(active.s));local b=math.min(box.x+box.w,to_x(active.e))
    if b>a then color({0.25,0.29,0.32});gfx.rect(a,ry,b-a,lane_height-2,1)end
   end
   for _,px in ipairs(ticks)do color(C.line);gfx.line(px,ry,px,ry+lane_height-2)end
   local clips,a,b
   if live then
    a=record_start;local pos=S.position();b=math.max(a,active and S.mode()=='section'and math.min(pos,active.e)or pos);clips={{s=a,e=b}}
    text(active and S.mode()=='section'and pos>=active.e and 'Recording tail...'or b>a and 'Recording...'or 'Recording lead-in...',x+12,ry+5,1,C.record,gutter-20)
    text(active and S.mode()=='section'and '2-bar handles / keep playing'or 'New pass',x+12,ry+26,3,C.muted,gutter-20)
   else
    clips,a,b=spans(row)
    text((row.favorite and '* 'or '')..take_name(row),x+12,ry+5,1,C.text,gutter-20)
    local tempo=row.tempo or {label='Tempo ?'}
    local suffix=row.playing and ' / playing' or tempo.different and ' / different' or ''
    text(tempo.label..suffix,x+12,ry+26,3,tempo.different and C.gold or row.playing and C.blue or C.muted,gutter-20)
   end
   for _,clip in ipairs(clips)do
    local left=math.max(box.x,to_x(clip.s));local right=math.min(box.x+box.w,to_x(clip.e))
    if right>left then
     color(live and C.record or row.playing and {0.28,0.49,0.62}or {0.30,0.39,0.47})
     gfx.rect(left,ry+5,right-left,34,1)
     if is_selected then color(C.text);gfx.rect(left,ry+5,right-left,34,0)end
     if right-left>65 then
      local tempo=row and row.tempo and row.tempo.clips and row.tempo.clips[clip.item]
      text((tempo and tempo..' / 'or '')..duration(clip.s,clip.e),left+8,ry+14,3,C.text,right-left-16)
     end
     if row then take_hits[#take_hits+1]={x=left,y=ry+5,w=right-left,h=34,row=row,clip=clip}end
    end
   end
   if row then take_hits[#take_hits+1]={x=x,y=ry,w=w,h=lane_height-2,row=row}end
   if is_selected and selected_count==1 and target then
    local left=math.max(box.x,to_x(target.s));local right=math.min(box.x+box.w,to_x(target.e))
    if right>left then color(C.gold);gfx.rect(left,ry+3,right-left,38,0);gfx.rect(left,ry+39,right-left,3,1)end
   end
   if is_selected then color(C.gold);gfx.rect(x,ry,3,lane_height-2,1)end
  end
  if count==0 then
   text('Record this instrument to see its takes here.',box.x+16,take_box.y+14,1,C.text,box.w-32)
   text('Each pass stays aligned with the song sections above, including unfinished takes.',box.x+16,take_box.y+41,3,C.muted,box.w-32)
  end
  local px=to_x(S.position());if px>=box.x and px<=box.x+box.w then color(C.gold);gfx.line(px,box.y,px,take_box.y+take_box.h);gfx.rect(px-3,box.y,6,7,1)end
  color(C.line);gfx.line(box.x,box.y,box.x,take_box.y+take_box.h)
  local detail='Comp / Take controls playback. In Take mode, click a take to hear it; Use in comp keeps the passage.'
  if selected_count>1 then
   detail=selected_count..' takes selected. Delete removes these whole passes across the recording set. Cmd+Z in REAPER restores them.'
  elseif chosen then
   local _,a,b=spans(chosen)
   if target then a,b=target.s,target.e end
   detail=take_name(chosen)..': selected passage '..fmt(a)..' - '..fmt(b)..' / '..duration(a,b)
   if chosen.tempo then detail=detail..' / recorded: '..chosen.tempo.label..(chosen.tempo.different and ' (different from song)'or '')end
   if chosen.note~='' then detail=detail..' / '..chosen.note end
  end
  if focus then detail='Close-up: drag the white Comp edge for free timing. Song section edges follow Snap. Back or Esc returns to the wider view.'end
  if g and g.moved and g.kind~='comp_edge'then detail=(g.valid and 'Preview: 'or'Invalid range: ')..fmt(g.a)..' to '..fmt(g.b)..' / '..duration(g.a,g.b)..' | Release to apply; Esc to cancel'end
  if g and g.kind=='comp_edge'then detail=g.valid and ('Comp edge: '..string.format('%.3f s',g.plan.pos)..' / available '..seconds(g.low)..' - '..seconds(g.high)..' | Release to apply; Esc to cancel')or g.error end
  text(detail,x,y+h-97,3,g and not g.valid and C.record or C.muted,w-155)
  text(count>0 and (take_scroll+1)..'-'..math.min(count,take_scroll+take_visible)..' of '..count..' lanes' or '',x+w-145,y+h-97,3,C.muted,145)
  local ay=y+h-74;local single=enabled and selected_count==1
  for _,spec in ipairs({{'Use in comp',0,132,'comp',C.blue},{'Favorite',140,96,'favorite'},{'Take note',244,105,'note'},
   {'Rename',357,90,'rename'},{selected_count>1 and ('Delete '..selected_count..' takes')or 'Delete take',455,160,'delete',C.record}})do
   local available=spec[4]=='delete' and selected_count>0 or single
   button(spec[1],x+spec[2],ay,spec[3],30,function()ui.take_action(spec[4])end,spec[5],enabled and available)
  end
  text('Zoom start/end: selected passage or section',x+631,ay+8,3,C.muted,w-631)
  local iy=y+h-33
  text('Section',x,iy+8,3,C.muted)
  if active then
   button(active.name..' (rename)',x+68,iy,222,30,ask_name,nil,enabled)
   button('Start: '..fmt(active.s),x+298,iy,170,30,function()ask_edge('s')end,nil,enabled)
   button('End: '..fmt(active.e),x+476,iy,170,30,function()ask_edge('e')end,nil,enabled)
   button('Length: '..duration(active.s,active.e),x+654,iy,190,30,ask_length,nil,enabled)
   button('Remove label',x+w-142,iy,142,30,function()
    if R.ShowMessageBox('Remove "'..active.name..'"? Recorded audio stays in place.','Remove section label',4)==6 then S.remove(active.key)end
   end,nil,enabled)
  else text('Choose a section above to edit its name, start, end, or length.',x+68,iy+8,3,C.muted,w-68)end
 end
 return V
end
