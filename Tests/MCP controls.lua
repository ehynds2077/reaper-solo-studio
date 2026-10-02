local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua')
local tmp=os.tmpname();os.remove(tmp);assert(os.execute('mkdir -p "'..tmp..'/control/requests" "'..tmp..'/control/responses"'))
local current='one';local transport=0;local now=0;local calls=0;local names={}
reaper={RecursiveCreateDirectory=function()end,genGuid=function()return 'panel-id'end,
 EnumProjects=function()return current,current..'.rpp'end,GetProjectName=function()return current end,
 GetMasterTrack=function(p)return p end,GetTrackGUID=function(p)return p..'-guid'end,
 CountTracks=function()return 2 end,GetProjectLength=function()return 30 end,
 GetPlayState=function()return transport end,GetAllProjectPlayStates=function()return transport end,
 Audio_IsRunning=function()return 1 end,time_precise=function()return now end,
 EnumerateFiles=function(_,i)return names[i+1]end}
local C=dofile(root..'/Scripts/solo_mcp.lua')({status=function()return {}end,
 execute=function(command,args)calls=calls+1;return {command=command,model=args.model}end},tmp..'/control')
local function request(args)
 return {id='aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa',instance_id='panel-id',expires_at=os.time()+10,command='start_mix',arguments=args or {project_id=C.status().project.id}}
end
local count=0;local function check(v,msg)assert(v,msg);count=count+1;print('PASS '..msg)end
check(C.status().project.name=='one','Native project name signature')
local a=request();current='two';check(not pcall(C.execute,a)and calls==0,'Switching projects rejects a queued mix')
current='one';a=request();a.instance_id='old';check(not pcall(C.execute,a),'Reloaded panel rejects old commands')
a=request();a.expires_at=os.time()-1;check(not pcall(C.execute,a),'Expired command cannot run late')
transport=4;check(not pcall(C.execute,request()),'Recording blocks start');transport=0
for _,args in ipairs({{rounds=101},{stop_after_usd=21},{model='bad;command'},{bounds={0,900}},{unknown=true},{references={'missing'}},{target_lufs=-6},{target_lufs=-25},{target_lufs=0/0}})do
 args.project_id=C.status().project.id;check(not pcall(C.execute,request(args)),'Invalid options are rejected before execution')
end
check(calls==0,'Rejected commands never reach mixer')
a=request();a.arguments.model='openai/gpt-6-luna';J.write(tmp..'/control/requests/'..a.id..'.json',a);names={a.id..'.json'}
C.poll();check(calls==1 and J.read(tmp..'/control/responses/'..a.id..'.json').result.model==a.arguments.model,'Inbox dispatches start and returns result')
J.write(tmp..'/control/requests/'..a.id..'.json',a);now=1;C.poll();check(calls==1,'A receipt prevents duplicate execution')
transport=1;a=request();a.command='cancel_mix';check(pcall(C.execute,a),'Cancellation remains available while playing')
C.close();check(J.read(tmp..'/control/studio.json').online==false,'Closed panel publishes offline status')
assert(os.execute('rm -r "'..tmp..'"'))
print(count..' MCP control checks passed')
