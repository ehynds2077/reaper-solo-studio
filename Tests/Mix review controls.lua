-- Exercise the native panel's real draw/key handlers without a GUI or network worker.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local state,transport,session,compared,kept,reverted,buttons
local J={array=function(t)return t or {}end,write=function()end}
function J.read(path)
 if path:match('/status.json$')then return {state=state,events={},measurements={}}end
 if path:match('/settings.json$')then return {}end
 if path:match('/library.json$')then return {references={},default=''}end
end
local B={json=J,recover=function()return session end,
 compare=function(_,mode)compared=mode;session.mode=mode end,
 keep=function()kept=true;session.finished=true end,
 revert=function()reverted=true;session.finished=true;return 0 end}
local original_dofile=dofile
function dofile(path)
 if path:match('/solo_mix_bridge.lua$')then return B end
 if path:match('/solo_models.lua$')then return {default='test',new=function()return {poll=function()end}end}end
 return original_dofile(path)
end
reaper={RecursiveCreateDirectory=function()end,GetExtState=function()return '/nonexistent-test-mix'end,
 GetPlayState=function()return transport end,time_precise=function()return 0 end,SetExtState=function()end}
gfx={setfont=function()end,rect=function()end,measurestr=function(v)return #v*7 end}
local factory=original_dofile(root..'/Scripts/solo_mix.lua')
local ui={text=function()end,color=function()end,colors={},run=function(fn)fn()end,
 button=function(label,x,y,w,h,fn,color,enabled)buttons[label]={run=fn,enabled=enabled~=false}end}
local function panel(t,status,mode)
 transport=t;state=status or 'review';session={path='/nonexistent-test-mix',mode=mode or 'candidate'}
 compared=nil;kept=false;reverted=false;buttons={}
 local x=factory({ns='test'},ui);x.draw(0,0,1200,700);return x
end
for _,t in ipairs({0,1,2,3})do
 local x=panel(t)
 check(buttons.Original.enabled and buttons.Candidate.enabled,'A/B enabled in transport '..t)
 check(buttons['Keep mix'].enabled and buttons.Revert.enabled,'Keep/revert enabled in transport '..t)
 check(buttons['Give feedback…'].enabled==(t==0),'Refinement requires stopped transport '..t)
 check(x.key(49)and compared=='original'and x.key(50)and compared=='candidate','Keyboard A/B works in transport '..t)
end
for _,t in ipairs({4,5,6,7})do
 local x=panel(t)
 check(not buttons.Original.enabled and not buttons.Candidate.enabled and not buttons['Keep mix'].enabled and not buttons.Revert.enabled,'Review disabled while recording '..t)
 x.key(49);x.key(50);check(compared==nil,'Keyboard cannot bypass recording lock '..t)
end
panel(1,'review_warning');check(not buttons['Keep mix'].enabled and buttons.Original.enabled,'Peak warning still prevents Keep after recovery')
panel(1,'running');check(not buttons['Keep mix'].enabled,'Interrupted worker recovers without accepting incomplete mix')
panel(1,'review','original');check(not buttons['Keep mix'].enabled and buttons.Candidate.enabled,'Recovered Original can switch back but cannot be kept')
print(passed..' mix review controls checks passed')
