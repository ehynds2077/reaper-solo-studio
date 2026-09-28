-- Exercise lifecycle/race behavior without an audio device or microphone capture.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local script=root..'/Scripts/Solo Studio - Finish section recording.lua'
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function setup()
 local s={project={},token='take-a',job='take-a\t12',valid=true,state=5,pos=10,time=0,queue={},stops=0}
 reaper={
  set_action_options=function()end,
  GetExtState=function()return s.job end,
  DeleteExtState=function()s.job=''end,
  EnumProjects=function()return s.project end,
  GetProjExtState=function(_,_,key)return 1,key=='section_watch_token' and s.token or ''end,
  SetProjExtState=function(_,_,key,v)if key=='section_watch_token'then s.token=v end end,
  atexit=function()end,
  ValidatePtr=function()return s.valid end,
  time_precise=function()return s.time end,
  GetPlayStateEx=function(p)assert(p==s.project);return s.state end,
  GetPlayPositionEx=function(p)assert(p==s.project);return s.pos end,
  Main_OnCommandEx=function(command,_,p)assert(command==40667 and p==s.project);s.stops=s.stops+1;s.state=0 end,
  defer=function(fn)s.queue[#s.queue+1]=fn end,
 }
 function s.tick()local fn=table.remove(s.queue,1);assert(fn,'Missing deferred poll');fn()end
 return s
end
local s=setup();dofile(script)
check(s.stops==0 and #s.queue==1,'Pass continues before its endpoint')
s.pos=11.999;s.tick();check(s.stops==0,'No early stop cuts the end of the section')
s.pos=12.02;s.tick();check(s.stops==1 and s.job=='' and s.token=='','Endpoint stops the owning project and clears the job')
s=setup();s.state=0;dofile(script);s.time=4;s.tick();s.state=5;s.pos=8;s.tick()
check(s.stops==0 and #s.queue==1,'Count-in and preroll can precede section recording')
s.pos=12;s.tick();check(s.stops==1,'Delayed recording still stops at the musical endpoint')
s=setup();dofile(script);s.state=0;s.tick();check(s.stops==0 and s.job=='','Manual stop cancels pending automatic stop')
s=setup();dofile(script);s.job='';s.tick();check(s.stops==0 and #s.queue==0,'Canceling a job does not stop unrelated playback')
s=setup();dofile(script);s.job='take-b\t20';s.token='take-b';s.tick()
check(s.stops==0 and s.job=='take-b\t20' and s.token=='take-b','An old pass cannot cancel a replacement pass')
s=setup();s.token='other-project';dofile(script);check(#s.queue==0 and s.stops==0,'A different project cannot acquire the recording job')
s=setup();dofile(script);s.valid=false;s.tick();check(s.stops==0 and s.job=='','Closing the project safely cancels its helper')
s=setup();s.job='';dofile(script);check(#s.queue==0 and s.stops==0,'Manually launching an idle helper does nothing')
print(total..' section-stop checks passed.')
