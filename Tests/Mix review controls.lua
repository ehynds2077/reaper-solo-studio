-- Exercise the native panel's real draw/key handlers without a GUI or network worker.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local state,transport,session,compared,kept,reverted,buttons,archived,foreign,extstate
local settings,writes,launches,input,job
local J={array=function(t)return t or {}end,write=function(path,value)writes[path]=value end}
function J.read(path)
 if path:match('/status.json$')then return {state=state,events={},measurements={}}end
 if path:match('/settings.json$')then return settings or {}end
 if path:match('/config.json$')then return job end
 if path:match('/library.json$')then return {references={},default=''}end
 if path:match('/snapshot.json$')then return {finished=false,project_path='other.rpp'}end
 if path:match('/connection.json$')then return {connected=true}end
end
local B={json=J,recover=function()return not foreign and session or nil end,
 guard=function()assert(transport==0,'Stop transport')end,
 compare=function(_,mode)compared=mode;session.mode=mode end,
 keep=function()kept=true;session.finished=true end,
 revert=function()reverted=true;session.finished=true;return 0 end,
 archive_current=function()assert(transport==0);archived=true;session.finished=true end}
local original_dofile=dofile
function dofile(path)
 if path:match('/solo_mix_bridge.lua$')then return B end
 if path:match('/solo_models.lua$')then return {default='test',new=function()return {
  poll=function()end,ensure=function()end,selected=function()return {name='test'}end,
  price=function()return 'test'end,message=function()end}end}end
 return original_dofile(path)
end
reaper={RecursiveCreateDirectory=function()end,GetExtState=function()return '/nonexistent-test-mix'end,
 GetPlayState=function()return transport end,time_precise=function()return 0 end,
 GetSet_LoopTimeRange2=function()return 0,20 end,SetExtState=function(_,_,v)extstate=v end,
 GetUserInputs=function()return true,input end,ExecProcess=function()launches=launches+1;return ''end}
gfx={setfont=function()end,rect=function()end,measurestr=function(v)return #v*7 end}
local factory=original_dofile(root..'/Scripts/solo_mix.lua')
local ui={text=function()end,color=function()end,colors={},run=function(fn)fn()end,
 button=function(label,x,y,w,h,fn,color,enabled)buttons[label]={run=fn,enabled=enabled~=false}end}
local function panel(t,status,mode,changed,other_project)
 transport=t;state=status or 'review';session={path='/nonexistent-test-mix',mode=mode or 'candidate',recovery_changed=changed}
 compared=nil;kept=false;reverted=false;archived=false;foreign=other_project;extstate=nil;buttons={}
 writes={};launches=0;job={direction='Original direction',rounds=20,stop_after_usd=2}
 local x=factory({ns='test'},ui);x.draw(0,0,1200,700);return x
end
for _,t in ipairs({0,1,2,3})do
 local x=panel(t)
 check(buttons.Original.enabled and buttons.Candidate.enabled,'A/B enabled in transport '..t)
 check(buttons['Keep mix'].enabled and buttons.Revert.enabled,'Keep/revert enabled in transport '..t)
 check(buttons['Give feedback…'].enabled==(t==0),'Refinement requires stopped transport '..t)
 check(buttons['Continue mixing'].enabled==(t==0),'Continue requires stopped transport '..t)
 check(x.key(49)and compared=='original'and x.key(50)and compared=='candidate','Keyboard A/B works in transport '..t)
end
for _,t in ipairs({4,5,6,7})do
 local x=panel(t)
 check(not buttons.Original.enabled and not buttons.Candidate.enabled and not buttons['Keep mix'].enabled and not buttons.Revert.enabled,'Review disabled while recording '..t)
 x.key(49);x.key(50);check(compared==nil,'Keyboard cannot bypass recording lock '..t)
end
panel(1,'review_warning');check(not buttons['Keep mix'].enabled and buttons.Original.enabled,'Peak warning still prevents Keep after recovery')
panel(1,'running');check(not buttons['Keep mix'].enabled,'Interrupted worker recovers without accepting incomplete mix')
panel(0,'cancelled');check(buttons['Give feedback…'].enabled and not buttons['Keep mix'].enabled,'Interrupted pass can continue from feedback without accepting unmeasured changes')
panel(1,'review','original');check(not buttons['Keep mix'].enabled and buttons.Candidate.enabled,'Recovered Original can switch back but cannot be kept')
panel(0,'review','original');check(not buttons['Continue mixing'].enabled,'Continue requires Candidate')
local resumed=panel(0,'review_warning');input='80,2';buttons['Pass limits: 60 rounds…'].run()
buttons['Continue mixing'].run()
check(launches==1 and job.resume and job.rounds==80 and job.stop_after_usd==2,'Continue uses latest limits instead of the old twenty-round job')
check(not archived and not kept and not reverted and resumed.pending(),'Continue preserves original comparison and session ownership')
check(job.direction:find('reuse session%-owned effects')~=nil,'Continuation asks to reuse owned effects')
settings={rounds=7,stop_after_usd=1};panel(0);input='Lift vocals';buttons['Give feedback…'].run()
check(job.rounds==7 and job.stop_after_usd==1 and job.direction:find('Lift vocals',1,true),'Feedback preserves explicitly configured smaller budgets')
settings=nil
local x=panel(0,'review','candidate',true)
check(buttons['Start a new mix'].enabled and not buttons.Original,'Changed project offers current-mix recovery instead of outdated A/B')
x.key(49);x.key(50);check(not compared,'Recovery page cannot trigger hidden A/B shortcuts')
-- Allow the cancellation marker to be created in a disposable location.
local tmp=os.tmpname();os.remove(tmp);assert(os.execute('mkdir -p "'..tmp..'"'));session.path=tmp
buttons['Start a new mix'].run();buttons={};x.draw(0,0,1200,700)
check(archived and not reverted and not kept and extstate==''and not x.pending(),'Fresh start clears the blocker without accepting or reverting the old candidate')
check(buttons['Create candidate mix'].enabled,'Fresh start opens configured setup without launching a worker')
for _,t in ipairs({1,4,5})do
 x=panel(t,'review','candidate',true);x.key(13)
 check(not buttons['Start a new mix'].enabled and not archived,'Fresh start and Enter wait for stopped transport '..t)
end
x=panel(0,'review','candidate',true);session.path=tmp;x.key(13)
check(archived and not x.pending(),'Enter opens fresh setup from recovery while stopped')
x=panel(0);session.path=tmp;x.close();check(not reverted and not kept and extstate==nil and x.pending(),'Panel close preserves unfinished mix for explicit review')
x=panel(0,'review','candidate',false,true);check(not buttons['Mix with AI'].enabled,'Real foreign session remains blocked')
x.key(13);buttons={};x.draw(0,0,1200,700)
check(buttons['Mix with AI']and not buttons['Create candidate mix'],'Enter cannot bypass foreign-session lock')
os.remove(tmp..'/cancel');os.remove(tmp)
print(passed..' mix review controls checks passed')
