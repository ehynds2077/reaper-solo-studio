-- Small, main-thread command inbox for the local stdio MCP server.
-- No arbitrary paths, code, REAPER actions, or automatic Keep/Revert operations.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua');local R=reaper
return function(callbacks,root)
 root=root or (os.getenv('HOME')or '')..'/Library/Application Support/Solo Studio/Mix/control'
 R.RecursiveCreateDirectory(root..'/requests',0);R.RecursiveCreateDirectory(root..'/responses',0)
 local C={};local last=-1;local instance=R.genGuid();local online=true
 local function read(path)local ok,data=pcall(J.read,path);if ok then return data end end
 local function finite(v,lo,hi)return type(v)=='number'and v==v and v>=lo and v<=hi end
 local function project_id(project)return R.GetTrackGUID(R.GetMasterTrack(project))..':'..tostring(project)end
 local function validate(command,a)
  assert(command=='start_mix'or command=='resume_mix'or command=='cancel_mix','Unknown command')
  assert(type(a)=='table','Arguments required')
  local allowed={project_id=true,session_id=true,model=true,direction=true,feedback=true,bounds=true,rounds=true,stop_after_usd=true,references=true,visual_analysis=true,target_lufs=true}
  for k in pairs(a)do assert(allowed[k],'Unknown option: '..tostring(k))end
  if a.model~=nil then assert(type(a.model)=='string'and #a.model<=160 and a.model:match('^[%w_./:%-]+$'),'Invalid model ID')end
  for _,k in ipairs({'direction','feedback'})do if a[k]~=nil then assert(type(a[k])=='string'and #a[k]<=8000,'Invalid '..k)end end
  if a.rounds~=nil then assert(finite(a.rounds,1,100)and a.rounds%1==0,'Rounds must be 1–100')end
  if a.stop_after_usd~=nil then assert(finite(a.stop_after_usd,.01,20),'Cost threshold must be $0.01–$20')end
  if a.visual_analysis~=nil then assert(type(a.visual_analysis)=='boolean','Invalid visual_analysis')end
  if a.target_lufs~=nil then assert(finite(a.target_lufs,-24,-8),'Loudness target must be -24 to -8 LUFS')end
  if a.bounds~=nil then assert(type(a.bounds)=='table'and #a.bounds==2 and finite(a.bounds[1],0,1e8)and finite(a.bounds[2],0,1e8)and a.bounds[2]-a.bounds[1]>=3 and a.bounds[2]-a.bounds[1]<=600,'Choose a 3–600 second passage')end
  if a.references~=nil then
   assert(type(a.references)=='table'and #a.references<=2,'Choose up to two reference IDs')
   local known={};local lib=read(root..'/../library.json')or {references={}}
   for _,ref in ipairs(lib.references or {})do known[ref.id]=true end
   for _,id in ipairs(a.references)do assert(type(id)=='string'and known[id],'Unknown reference ID')end
  end
 end
 function C.status()
  local project,path=R.EnumProjects(-1,'');local name=R.GetProjectName(project)
  return {protocol=1,instance_id=instance,online=online,updated=os.time(),
   project={id=project_id(project),path=path,name=name,tracks=R.CountTracks(project),duration=R.GetProjectLength(project)},
   transport=R.GetPlayState(),engine_running=R.Audio_IsRunning()~=0,mix=callbacks.status()}
 end
 function C.execute(request)
  assert(request.instance_id==instance,'Panel was reloaded. Refresh studio status before retrying.')
  assert(finite(request.expires_at,os.time(),os.time()+60),'Command expired; no action was taken')
  validate(request.command,request.arguments)
  local project=R.EnumProjects(-1,'')
  assert(request.arguments.project_id==project_id(project),'Active project changed; no action was taken')
  if request.command~='cancel_mix'then assert(R.GetAllProjectPlayStates()==0,'Stop playback and recording in every project before mixing')end
  request.arguments.source='mcp'
  return callbacks.execute(request.command,request.arguments)
 end
 function C.poll()
  if R.time_precise()-last<.25 then return end;last=R.time_precise()
  J.write(root..'/studio.json',C.status())
  local pending={}
  for i=0,127 do
   local name=R.EnumerateFiles(root..'/requests',i);if not name then break end
   if name:match('^[%x%-]+%.json$')then pending[#pending+1]=name end
  end
  table.sort(pending)
  local name=pending[1];if not name then return end
  local path=root..'/requests/'..name;local response=root..'/responses/'..name
  -- The receipt is written before a mutation. A crash leaves an ambiguous
  -- receipt that must be inspected, never replayed as a second paid mix.
  if read(response)then os.remove(path);return end
  local request=read(path)
  J.write(response,{executing=true,command=request and request.command,time=os.time()})
  local ok,result=pcall(function()
   assert(request and request.id..'.json'==name,'Invalid command envelope')
   return C.execute(request)
  end)
  J.write(response,ok and {result=result}or {error=tostring(result):match('^[^\n]+')})
  os.remove(path);J.write(root..'/studio.json',C.status())
 end
 function C.close()online=false;J.write(root..'/studio.json',C.status())end
 return C
end
