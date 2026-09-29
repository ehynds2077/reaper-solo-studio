-- Local song catalog and native project-tab navigation. Never closes a song.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua');local R=reaper
local function exists(path)local f=io.open(path,'rb');if not f then return false end;f:close();return true end
local function title(path)return path:match('([^/]+)%.[Rr][Pp][Pp]$')or 'Untitled song'end
local function normalized(path)return (path:gsub('\\','/'):gsub('/+','/'):gsub('/%./','/'))end
local function excluded(path)
 local lower='/'..path:lower()..'/'
 for _,part in ipairs({'tests','templates','projecttemplates','backups','solo studio mixes','.git','node_modules','media','_media'})do
  if lower:find('/'..part..'/',1,true)then return true end
 end
 return exists((path:match('^(.*)/')or '')..'/bounce.json')
end
local function metadata(path,require_solo)
 local f=io.open(path,'rb');if not f then return end
 local first=f:read('*l')or '';if not first:match('^<REAPER_PROJECT')then f:close();return end
 local row={path=path,title=title(path),tracks=0};local solo=false;local bytes=0
 for line in f:lines()do
  bytes=bytes+#line;if bytes>64000000 then f:close();return end
  if line:match('^%s*<TRACK[%s>]')then row.tracks=row.tracks+1 end
  row.bpm=row.bpm or tonumber(line:match('^%s*TEMPO%s+([%d.]+)'))
  if line:upper():match('^%s*<SOLOSTUDIO_V1%s*$')then solo=true end
 end
 f:close();if require_solo and not solo then return end
 return row
end
return function(M,options)
 local o=options or {};local P={}
 P.root=o.root or (os.getenv('HOME')or '')..'/Desktop/Solo Studio Songs'
 P.catalog=o.catalog or R.GetResourcePath()..'/Solo Studio/projects.json'
 P.template=o.template or R.GetResourcePath()..'/ProjectTemplates/Solo Studio - Ethan X32.RPP'
 if not exists(P.template)then P.template=dir..'/../Templates/Solo Studio - Ethan X32.RPP'end
 local data=J.read(P.catalog)or {schema=1,projects=J.array()}
 assert(data.schema==1 and type(data.projects)=='table','The Solo Studio project catalog could not be read. It has been left untouched: '..P.catalog)
 local entries={}
 for _,row in ipairs(data.projects)do if type(row.path)=='string'then row.path=normalized(row.path);entries[row.path]=row end end
 local last_observed
 local function persist()
  data.projects=J.array();for _,row in pairs(entries)do data.projects[#data.projects+1]=row end
  table.sort(data.projects,function(a,b)return a.path<b.path end)
  R.RecursiveCreateDirectory(P.catalog:match('^(.*)/'),0);J.write(P.catalog,data)
 end
 local function remember(path,explicit)
  path=normalized(path)
  if not explicit and excluded(path)then return end
  local row=metadata(path,not explicit);if not row then return end
  local previous=entries[path]
  row.display_name=previous and previous.display_name
  row.title=row.display_name or row.title
  row.last_opened=previous and previous.last_opened or 0
  row.added=previous and previous.added or os.time()
  entries[path]=row;return row
 end
 local function open_projects()
  local out={}
  for i=0,1023 do local project,path=R.EnumProjects(i,'');if not project then break end
   out[#out+1]={project=project,path=normalized(path)}
  end
  return out
 end
 function P.observe()
  local project,path=R.EnumProjects(-1,'');path=normalized(path)
  local key=tostring(project)..path;if key==last_observed then return end
  last_observed=key
  if path~=''then
   local _,sets=R.GetProjExtState(project,M.ns,'sets')
   if entries[path]or (sets~=''and not excluded(path))then
    local row=remember(path,true)
    if row then row.last_opened=os.time();persist()end
   end
  end
 end
 function P.refresh()
  for _,open in ipairs(open_projects())do
   local _,sets=R.GetProjExtState(open.project,M.ns,'sets')
   if open.path~=''and sets~=''then remember(open.path,entries[open.path]~=nil)end
  end
  local ini=io.open(o.ini or R.get_ini_file(),'r');local recent=false
  if ini then for line in ini:lines()do
   local section=line:match('^%[([^%]]+)%]');if section then recent=section:lower()=='recent'end
   local path=recent and line:match('^recent%d+=(.+)$');if path then remember(path:gsub('\r$',''),false)end
  end;ini:close()end
  local visited=0
  local function scan(folder,depth)
   if depth>5 or visited>2000 then return end;visited=visited+1
   R.EnumerateFiles(folder,-1)
   for i=0,10000 do local name=R.EnumerateFiles(folder,i);if not name then break end
    if name:lower():match('%.rpp$')then remember(folder..'/'..name,false)end
   end
   R.EnumerateSubdirectories(folder,-1)
   for i=0,2000 do local name=R.EnumerateSubdirectories(folder,i);if not name then break end
    local child=folder..'/'..name
    if name:sub(1,1)~='.'and not excluded(child)then scan(child,depth+1)end
   end
  end
  scan(P.root,0)
  -- Refresh saved metadata too; missing entries remain available in the list.
  for path in pairs(entries)do remember(path,true)end
  last_observed=nil;P.observe();persist()
 end
 function P.list()
  P.observe();local rows={};local by_path={};local current=R.EnumProjects(-1,'')
  for path,saved in pairs(entries)do
   local row={};for k,v in pairs(saved)do row[k]=v end
   row.key=path;row.missing=not exists(path);rows[#rows+1]=row;by_path[path]=row
  end
  for _,open in ipairs(open_projects())do
   local row=by_path[open.path];local _,sets=R.GetProjExtState(open.project,M.ns,'sets')
   if not row and (open.path==''and (sets~=''or open.project==current))then
    row={key=tostring(open.project),path='',title='Untitled song',last_opened=0};rows[#rows+1]=row
   end
   if row and (not row.current or open.project==current)then
    row.project=open.project;row.current=open.project==current;row.dirty=R.IsProjectDirty(open.project)~=0
    row.tracks=R.CountTracks(open.project);row.bpm=R.GetProjectTimeSignature2(open.project);row.missing=false
   end
  end
  table.sort(rows,function(a,b)
   if not not a.current~=not not b.current then return not not a.current end
   if a.last_opened~=b.last_opened then return a.last_opened>b.last_opened end
   if a.title~=b.title then return a.title:lower()<b.title:lower()end
   return a.key<b.key
  end)
  return rows
 end
 function P.add(path)
  assert(type(path)=='string'and path:lower():match('%.rpp$'),'Choose a REAPER .RPP project.')
  local row=remember(path,true);assert(row,'That project could not be read. Choose an existing REAPER .RPP file.')
  persist();return row.path
 end
 function P.available()
  local state=R.GetAllProjectPlayStates and R.GetAllProjectPlayStates()or R.GetPlayState()
  return state&4==0 and not (o.busy and o.busy())
 end
 function P.rename(row,name,expected)
  assert(P.available(),'Finish recording or the current AI mix operation before renaming a song.')
  assert(not expected or R.EnumProjects(-1,'')==expected,'The active project changed. Select the song again.')
  assert(row and row.path~=''and entries[row.path],'Save this project once before renaming it in Projects.')
  local saved=entries[row.path]
  assert(saved.title==row.title,'This song name changed. Select it again before renaming.')
  name=(name or ''):gsub('^%s+',''):gsub('%s+$','')
  local length=utf8.len(name)
  assert(length and length>0 and length<=100 and not name:find('%c'),'Use a song name of 1–100 characters without line breaks.')
  if name==saved.title then return row.path end
  -- The catalog name is independent of the RPP path, which also identifies
  -- saved bounces and AI mix sessions. Do not save or mutate the open project.
  local old_title,old_name=saved.title,saved.display_name
  saved.title=name;saved.display_name=name
  local ok,err=pcall(persist)
  if not ok then saved.title=old_title;saved.display_name=old_name;error(err,0)end
  return row.path
 end
 local function prepare(expected)
  assert(P.available(),'Finish recording or the current AI mix operation before switching songs.')
  assert(not expected or R.EnumProjects(-1,'')==expected,'The active project changed. Try again from the Projects view.')
  if o.before_switch then o.before_switch()end
  if R.GetPlayState()~=0 then R.OnStopButton()end
 end
 function P.open(row,expected)
  local target
  for _,open in ipairs(open_projects())do
   if row.project==open.project or (row.path~=''and row.path==open.path)then target=open.project;break end
  end
  assert(target or (row.path~=''and exists(row.path)),'This song is missing. Use Add existing to locate its .RPP file.')
  prepare(expected)
  if target then R.SelectProjectInstance(target)
  else
   local previous=R.EnumProjects(-1,'');R.Main_OnCommand(41929,0);local tab=R.EnumProjects(-1,'')
   assert(tab~=previous,'REAPER could not create a project tab.')
   R.Main_openProject(row.path)
   local _,path=R.EnumProjects(-1,'')
   if normalized(path)~=row.path then R.SelectProjectInstance(previous);error('REAPER did not open that song. Your previous project is still open.')end
  end
  last_observed=nil;P.observe();return R.EnumProjects(-1,'')
 end
 function P.create(name,bpm,expected)
  name=(name or ''):gsub('^%s+',''):gsub('%s+$','')
  assert(#name>0 and #name<=100 and name~='.'and name~='..'and not name:find('[%c/\\:*?"<>|]'),'Use a song name of 1–100 characters without slashes or filename punctuation.')
  bpm=tonumber(bpm);assert(bpm and bpm>=20 and bpm<=300,'Choose a tempo from 20 to 300 BPM.')
  local folder=P.root..'/'..name;local path=folder..'/'..name..'.RPP'
  assert(not exists(path),'A song with this name already exists. Open it from Projects or choose another name.')
  assert(exists(P.template),'Install the Solo Studio - Ethan X32.RPP template in REAPER/ProjectTemplates first.')
  prepare(expected);local previous=R.EnumProjects(-1,'');local project
  local ok,err=xpcall(function()
   R.RecursiveCreateDirectory(folder..'/Media',0)
   R.Main_OnCommand(41929,0);project=R.EnumProjects(-1,'');assert(project~=previous,'REAPER could not create a project tab.')
   R.Main_openProject('template:'..P.template)
   assert(R.CountTracks(project)==15 and R.CountMediaItems(project)==0,'The full-band template must contain 15 empty tracks.')
   local sets=M.sets();assert(#sets==6,'The template recording sets could not be restored.')
   for _,set in ipairs(sets)do if set.name=='Scratch guitar + vocal'then M.choose_set(set.id)end end
   assert(#M.tracks()==2,'The scratch recording set could not be selected.')
   for i=0,R.CountTracks(project)-1 do R.SetMediaTrackInfo_Value(R.GetTrack(project,i),'I_RECMON',0)end
   R.GetSetProjectInfo_String(project,'RECORD_PATH','Media',true);R.SetCurrentBPM(project,bpm,false)
   R.SetProjExtState(project,M.ns,'song.title',name)
   R.Main_SaveProjectEx(project,path,8)
   assert(select(2,R.EnumProjects(-1,''))==path and exists(path),'The song could not be saved. Its new tab is retained so you can use Save as.')
  end,debug.traceback)
  if not ok then R.SelectProjectInstance(previous);error(err,0)end
  remember(path,true);last_observed=nil;P.observe();return project,path
 end
 function P.prompt_new()
  local expected=R.EnumProjects(-1,'')
  assert(P.available(),'Finish recording or the current AI mix operation before starting a song.')
  local ok,value=R.GetUserInputs('New full-band song',2,'Song name:,Tempo (20–300 BPM):,extrawidth=240',',120')
  if not ok then return end
  local name,bpm=value:match('^(.*),([^,]+)$');return P.create(name,bpm,expected)
 end
 return P
end
