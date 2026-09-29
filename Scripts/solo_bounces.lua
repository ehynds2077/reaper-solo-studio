-- Versioned stereo exports. Rendering takes place in a disposable project copy.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua');local R=reaper
local B={json=J}
B.root=(os.getenv('HOME')or '')..'/Desktop/Solo Studio Mixes'
local worker=dir..'/Bounces/library.py'
local f=io.open(worker);if f then f:close()else worker=dir..'/../Bounces/library.py'end
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
local function exists(path)local f=io.open(path,'rb');if not f then return false end;f:close();return true end
local function read(path)local ok,v=pcall(J.read,path);return ok and v or nil end
local function slug(s)return (s:gsub('[%c/\\:*?"<>|]','-'):gsub('^%s+',''):gsub('%s+$',''):sub(1,90))end
local function guid()return R.genGuid():gsub('[^%w]','')end
function B.launch(args)
 assert(exists(worker),'Install Bounces/library.py beside the Solo Studio Lua scripts, then try again.')
 local cmd='/usr/bin/python3 '..quote(worker)
 for _,arg in ipairs(args)do cmd=cmd..' '..quote(arg)end
 assert(R.ExecProcess(cmd,-1),'Could not start the local bounce helper.')
end
function B.identity()
 local project,path=R.EnumProjects(-1,'')
 local _,restored=R.GetProjExtState(project,'SoloStudio_bounces','source')
 local _,restored_title=R.GetProjExtState(project,'SoloStudio_bounces','title')
 local archive=path~=''and read((path:match('^(.*)/')or '')..'/bounce.json')
 local snapshot=path:match('/Session%.RPP$')or path:match('/Instrumental session%.RPP$')
 -- REAPER's master-track GUID is regenerated on reopen; saved project paths
 -- remain stable across launches. Archived copies carry their originating ID.
 return {project=project,path=path,id=restored~=''and restored or snapshot and archive and archive.project_id or (path~=''and path or tostring(project)),
  title=restored_title~=''and restored_title or snapshot and archive and archive.project_title or path:match('([^/]+)%.[Rr][Pp][Pp]$')or 'Untitled song'}
end
local function settings()
 return read(B.root..'/settings.json')or {projects={}}
end
function B.vocals()
 local identity=B.identity();local config=settings();local choices=config.projects[identity.id]or {};local rows={}
 for i=0,R.CountTracks(0)-1 do
  local tr=R.GetTrack(0,i);local id=R.GetTrackGUID(tr);local _,name=R.GetTrackName(tr)
  local lower=' '..name:lower():gsub('[^%w]',' ')..' '
  local vocal=lower:find(' vocal')~=nil or lower:find(' vox ')~=nil or lower:find(' bgv')~=nil or lower:find(' bv ')~=nil
  if choices[id]~=nil then vocal=choices[id]end
  rows[#rows+1]={id=id,name=name,excluded=vocal}
 end
 return rows
end
function B.set_vocal(id,value)
 local identity=B.identity();local config=settings();config.projects[identity.id]=config.projects[identity.id]or {}
 config.projects[identity.id][id]=value;R.RecursiveCreateDirectory(B.root,0);J.write(B.root..'/settings.json',config)
end
function B.list()
 local id=B.identity().id;local rows={}
 R.EnumerateSubdirectories(B.root,-1)
 for i=0,10000 do
  local name=R.EnumerateSubdirectories(B.root,i);if not name then break end
  local folder=B.root..'/'..name;local row=read(folder..'/bounce.json')
  if row and row.project_id==id then
   row.folder=folder;local status=read(folder..'/status.json');row.status=status and status.state or row.state or 'incomplete';row.detail=status and status.message
   rows[#rows+1]=row
  end
 end
 table.sort(rows,function(a,b)if a.created_at==b.created_at then return a.id>b.id end;return a.created_at>b.created_at end)
 return rows
end
local function assert_stopped()assert(R.GetPlayState()==0,'Stop playback and recording before bouncing or opening a session.')end
local function render(project,folder,name,bounds)
 local numbers={RENDER_SETTINGS=0,RENDER_BOUNDSFLAG=0,RENDER_STARTPOS=bounds[1],RENDER_ENDPOS=bounds[2],
  RENDER_CHANNELS=2,RENDER_TAILFLAG=1,RENDER_TAILMS=2000,RENDER_ADDTOPROJ=0,RENDER_DITHER=0,RENDER_NORMALIZE=0,RENDER_SRATE=48000}
 for key,value in pairs(numbers)do R.GetSetProjectInfo(project,key,value,true)end
 for key,value in pairs({RENDER_FORMAT='ZXZhdxgAAA==',RENDER_FORMAT2='',RENDER_FILE=folder,RENDER_PATTERN=name})do
  R.GetSetProjectInfo_String(project,key,value,true)
 end
 R.Main_OnCommand(42230,0)
 local path=folder..'/'..name..'.wav';local source=R.PCM_Source_CreateFromFile(path)
 assert(source,'Render cancelled or no audio was created. The incomplete export is retained for inspection.')
 local length=R.GetMediaSourceLength(source);R.PCM_Source_Destroy(source)
 assert(length>=bounds[2]-bounds[1]+2-.05,'Render did not finish. Try bouncing again.')
 return path
end
local function mute_vocals(project,ids)
 local missing={};for id in pairs(ids)do missing[id]=true end
 for i=0,R.CountTracks(project)-1 do
  local tr=R.GetTrack(project,i);local id=R.GetTrackGUID(tr)
  if ids[id]then
   -- Mute automation can unmute a track during offline rendering. Disable only
   -- that envelope in the disposable copy, retaining all other automation.
   local env=R.GetTrackEnvelopeByChunkName(tr,'<MUTEENV')
   if env then
    local ok,chunk=R.GetEnvelopeStateChunk(env,'',false);assert(ok,'Could not read vocal mute automation')
    local disabled,count=chunk:gsub('(\n%s*ACT%s+)1','%10',1)
    if count>0 then assert(R.SetEnvelopeStateChunk(env,disabled,false),'Could not disable vocal mute automation')end
   end
   R.SetMediaTrackInfo_Value(tr,'B_MUTE',1);missing[id]=nil
  end
 end
 assert(next(missing)==nil,'Vocal tracks changed while preparing the bounce. Select them again.')
end
function B.export(options)
 assert_stopped();local identity=B.identity()
 assert(identity.path~='','Save this song in REAPER once before creating a bounce.')
 assert(R.CountMediaItems(identity.project)>0,'Record or import audio before bouncing.')
 assert(type(options.title)=='string'and options.title:match('%S'),'Give this version a name.')
 local bounds=options.bounds or {0,R.GetProjectLength(identity.project)}
 assert(bounds[1]>=0 and bounds[2]>bounds[1],'Choose a nonempty range to bounce.')
 for i=0,R.CountTracks(identity.project)-1 do
  assert(R.GetMediaTrackInfo_Value(R.GetTrack(identity.project,i),'I_SOLO')==0,'Clear track solos before bouncing the mix.')
 end
 local id=guid();local folder=B.root..'/'..slug(identity.title)..' - '..os.date('%Y-%m-%d %H%M%S')..' - '..slug(options.title)..' - '..id:sub(1,8)
 R.RecursiveCreateDirectory(folder,0)
 local row={schema=1,id=id,project_id=identity.id,project_title=identity.title,source_project=identity.path,
  title=options.title,notes=options.notes or '',created_at=os.time(),bounds=bounds,tail_seconds=2,
  vocals=J.array(),state='rendering',full='Full mix.wav',instrumental='Instrumental.wav',session='Session.RPP'}
 local excluded={}
 for _,v in ipairs(options.vocals or B.vocals())do if v.excluded then excluded[v.id]=true;row.vocals[#row.vocals+1]={id=v.id,name=v.name}end end
 J.write(folder..'/bounce.json',row)
 local dirty=R.IsProjectDirty(identity.project);local work
 local ok,err=xpcall(function()
  -- options=0 writes a copy without renaming the working project.
  R.Main_SaveProjectEx(identity.project,folder..'/Session.RPP',0)
  assert(exists(folder..'/Session.RPP'),'REAPER could not save the session snapshot.')
  if dirty~=0 and R.IsProjectDirty(identity.project)==0 then R.MarkProjectDirty(identity.project)end
  R.Main_OnCommand(41929,0);work=R.EnumProjects(-1,'')
  assert(work~=identity.project,'Could not create a temporary render project.')
  R.Main_openProject('noprompt:'..folder..'/Session.RPP')
  work=R.EnumProjects(-1,'')
  -- Never monitor or arm hardware inputs in the render copy.
  for i=0,R.CountTracks(work)-1 do local tr=R.GetTrack(work,i);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0);R.SetMediaTrackInfo_Value(tr,'I_RECMON',0)end
  render(work,folder,'Full mix',bounds)
  mute_vocals(work,excluded)
  R.Main_SaveProjectEx(work,folder..'/Instrumental session.RPP',0)
  render(work,folder,'Instrumental',bounds)
 end,debug.traceback)
 local cleaned,cleanup_error=pcall(function()if work and work~=identity.project then
  -- Save the disposable state under its own filename to avoid a close prompt
  -- and to keep the original full-mix snapshot immutable.
  R.SelectProjectInstance(work);R.Main_SaveProjectEx(work,folder..'/Render working copy.RPP',8);R.Main_OnCommand(40860,0)
  os.remove(folder..'/Render working copy.RPP')
 end end)
 R.SelectProjectInstance(identity.project)
 if not cleaned then ok=false;err=cleanup_error end
 if not ok then
  row.state='failed';J.write(folder..'/bounce.json',row);J.write(folder..'/status.json',{state='failed',message=tostring(err):match('^[^\n]+')})
  error(err,0)
 end
 row.state='packaging';J.write(folder..'/bounce.json',row)
 J.write(folder..'/status.json',{state='packaging',message='Preserving recordings and creating phone copies…'})
 B.launch({'archive',folder});row.folder=folder;return row
end
function B.reveal(row)R.RecursiveCreateDirectory(B.root,0);R.ExecProcess('/usr/bin/open '..quote(row and row.folder or B.root),-1)end
function B.open_session(row,instrumental)
 assert_stopped();assert(row.status=='ready','Wait for the snapshot and recordings to finish archiving.')
 local filename=row.folder..'/'..(instrumental and 'Instrumental session.RPP'or 'Session.RPP')
 assert(exists(filename),'The saved session could not be found.')
 R.Main_OnCommand(41929,0);R.Main_openProject('template:'..filename)
 R.SetProjExtState(0,'SoloStudio_bounces','source',row.project_id)
 R.SetProjExtState(0,'SoloStudio_bounces','title',row.project_title)
end
function B.retry(row)
 assert(row.status=='failed'and exists(row.folder..'/Full mix.wav')and exists(row.folder..'/Instrumental.wav'),'This export needs to be bounced again.')
 B.launch({'archive',row.folder})
end
function B.read_status(row)return read(row.folder..'/status.json')end
B.quote=quote
return B
