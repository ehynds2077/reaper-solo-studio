local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua');local prefix='/private/tmp/solo-project-catalog-'..os.time()
local files={};local function write(name,text)local path=prefix..name;local f=assert(io.open(path,'w'));f:write(text);f:close();files[#files+1]=path;return path end
local rpp='<REAPER_PROJECT 0.1 7.55 1\n TEMPO 132 4 4\n <TRACK {1}\n >\n <EXTSTATE\n <SOLOSTUDIO_V1\n SETS abc\n >\n >\n>\n'
local song=write('-Song.RPP',rpp);local other=write('-Other.RPP',rpp);local ordinary=write('-Ordinary.RPP',rpp:gsub('SOLOSTUDIO_V1','OTHER'));local missing=prefix..'-Missing.RPP'
local ini=write('.ini','[Recent]\nrecent01='..song..'\nrecent02='..ordinary..'\n[RecentFX]\nrecent01='..other..'\n')
local catalog=prefix..'.json';files[#files+1]=catalog
local projects={{path=song,sets='abc',dirty=1},{path='',sets='abc',dirty=1}};local current=projects[1];local state=0;local loads=0;local busy=false;local before=0
local R={GetResourcePath=function()return prefix end,EnumProjects=function(i)local p=i==-1 and current or projects[i+1];return p,p and p.path or ''end,
 GetProjExtState=function(p)return 1,p.sets end,GetProjectTimeSignature2=function()return 145,4 end,CountTracks=function()return 15 end,
 IsProjectDirty=function(p)return p.dirty end,RecursiveCreateDirectory=function()end,get_ini_file=function()return ini end,
 EnumerateFiles=function(_,i)if i==0 then return other:match('([^/]+)$')end end,EnumerateSubdirectories=function()end,
 GetAllProjectPlayStates=function()return state end,GetPlayState=function()return state end,OnStopButton=function()state=0 end,
 SelectProjectInstance=function(p)current=p end,Main_OnCommand=function(cmd)assert(cmd==41929);current={path='',sets='',dirty=0};projects[#projects+1]=current end,
 Main_openProject=function(path)loads=loads+1;if not path:find('Missing')then current.path=path;current.sets='abc'end end}
local env=setmetatable({reaper=R},{__index=_G})
local factory=assert(loadfile(root..'/Scripts/solo_projects.lua','t',env))()
local P=factory({ns='SoloStudio_v1'},{root='/private/tmp',catalog=catalog,template=song,busy=function()return busy end,before_switch=function()before=before+1 end})
local passed=0;local function check(value,label)assert(value,label);passed=passed+1;print('PASS '..label)end
local function find(path)for _,row in ipairs(P.list())do if row.path==path then return row end end end
P.refresh()
check(find(song).current and find(song).dirty and find(song).bpm==145,'Current project displays live tempo and unsaved status')
check(find(other) and not find(ordinary),'Root scan discovers Solo Studio songs and ignores other recent sections and ordinary projects')
check(find('').project==projects[2],'Unsaved Solo Studio tab stays reachable')
check(#J.read(catalog).projects==2,'Unsaved tabs are not persisted as fake files')
check(P.add(ordinary)==ordinary and find(ordinary),'Add existing explicitly accepts a standard REAPER song')
local f=assert(io.open(song,'rb'));local original_bytes=f:read('*a');f:close()
local old_row=find(song);P.rename(old_row,'  New song title  ',current);P.refresh()
check(find(song).title=='New song title'and find(song).key==song,'Rename survives discovery refresh and keeps stable identity')
f=assert(io.open(song,'rb'));local after=f:read('*a');f:close()
check(after==original_bytes and current==projects[1]and current.dirty==1 and loads==0 and before==0,'Rename leaves the RPP bytes, unsaved edits and active tab intact')
check(not pcall(P.rename,old_row,'Stale name'),'A stale name cannot overwrite a later rename')
check(not pcall(P.rename,find(song),'   ')and not pcall(P.rename,find(song),'Bad\nname'),'Empty and multiline names are rejected')
check(not pcall(P.rename,find(''),'Draft name'),'Unsaved unnamed projects must be saved before library rename')
state=4;check(not pcall(P.rename,find(song),'Recording'),'Recording blocks the rename dialog action');state=0
busy=true;check(not pcall(P.rename,find(song),'Mixing'),'AI operations block renaming');busy=false
check(not pcall(P.rename,find(song),'Wrong project',projects[2]),'Changed project context rejects a stale rename dialog')
P.rename(find(other),'Closed song title');check(find(other).title=='Closed song title'and loads==0,'Closed songs can be renamed without opening them')
local saved_catalog=P.catalog;P.catalog='/private/tmp/no-such-solo-rename-folder/catalog.json'
check(not pcall(P.rename,find(song),'Failed write')and find(song).title=='New song title','Failed catalog write preserves the previous name')
P.catalog=saved_catalog

state=1;P.open(find(''))
check(current==projects[2]and state==0 and loads==0 and projects[1].dirty==1,'Switch reuses an open tab, stops playback, and preserves dirty work')
P.open(find(song));check(current==projects[1]and loads==0,'Returning to an open song never reloads its saved file')
local old=before;state=4;check(not pcall(P.open,find(other))and before==old,'Recording blocks switching before any callback or tab mutation')
state=0;busy=true;check(not pcall(P.open,find(other))and before==old,'Active AI mix blocks project switching')
busy=false;check(not pcall(P.open,find(other),projects[2]),'Stale dialog project is rejected')
check(not pcall(P.create,'../unsafe',120)and not pcall(P.create,'Song',999),'Invalid song name and tempo do not create a tab')
P.open(find(other));check(loads==1 and current.path==other and #projects==3,'A closed song opens in a new tab without closing earlier songs')
os.remove(other);check(find(other).missing==false,'An open project remains usable when its file has moved')
projects[3]=nil;current=projects[1];check(find(other).missing and not pcall(P.open,find(other)),'A missing closed song stays in the list with a clear failure')
local Q=factory({ns='SoloStudio_v1'},{root='/private/tmp',catalog=catalog,template=song})
check(#Q.list()==4,'Catalog survives a module reload, including missing songs and unsaved open tabs')
local restored={};for _,row in ipairs(Q.list())do restored[row.path]=row.title end
check(restored[song]=='New song title'and restored[other]=='Closed song title','Renamed open and missing songs retain names after a reload')
local old_ext=R.GetProjExtState
R.GetProjExtState=function(project,namespace)if namespace=='SoloStudio_bounces'then return 0,''end;return old_ext(project)end
local bounce_env=setmetatable({reaper=R,dofile=function(path)
 if path:match('/solo_json.lua$')then return {read=function(file)if file:match('/Solo Studio/projects.json$')then return J.read(catalog)end end}end
 return dofile(path)
end},{__index=_G})
local B=assert(loadfile(root..'/Scripts/solo_bounces.lua','t',bounce_env))()
check(B.identity().title=='New song title'and B.identity().id==song,'Future bounce names use the renamed title without changing the saved mix identity')
R.GetProjExtState=function(_,_,key)return 1,key=='source'and song or 'Old archive title'end
check(B.identity().title=='New song title'and B.identity().id==song,'Restored archived sessions retain their mix history and follow the current song name')
R.GetProjExtState=old_ext
for _,path in ipairs(files)do os.remove(path)end
print(passed..' project library checks passed')
