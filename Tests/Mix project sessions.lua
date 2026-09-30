-- Read-only recovery across independent songs, using real journal files.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua')
local folder=os.tmpname();os.remove(folder);assert(os.execute('mkdir -p "'..folder..'"'))
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local active,file,tracks='A','A.rpp',{{id='track-A',volume=.5,pan=0}}
local children,created={},{}
reaper={
 EnumProjects=function()return active,file end,CountTracks=function()return #tracks end,
 GetTrack=function(_,i)return tracks[i+1]end,GetTrackGUID=function(tr)return tr.id end,
 GetMediaTrackInfo_Value=function(tr,key)return key=='D_VOL'and tr.volume or tr.pan end,
 GetProjectStateChangeCount=function()return 10 end,GetPlayState=function()return 0 end,
 TrackFX_GetCount=function()return 0 end,
 EnumerateSubdirectories=function(path,i)assert(path==folder);return i>=0 and children[i+1]or nil end,
}
-- No project mutation, rendering, transport, or global-state write API is exposed.
local B=dofile(root..'/Scripts/solo_mix_bridge.lua')
local function journal(id,project,track,updated,finished,listed)
 local path=folder..'/'..id;assert(os.execute('mkdir -p "'..path..'"'));created[#created+1]=path
 local s={original=J.array({{id=track,volume=1,pan=0}}),expected={[track]={volume=.5,pan=0}},
  owned=J.array(),bounds={0,8},mode='candidate',project_path=project,finished=finished or false}
 J.write(path..'/snapshot.json',s);J.write(path..'/status.json',{state='review',updated=updated})
 if listed~=false then children[#children+1]=id end
 return path
end
local a=journal('A','A.rpp','track-A',10)
local before=J.encode(J.read(a..'/snapshot.json'))
check(B.find_session(folder,a).path==a,'Legacy unfinished mix is recovered for its own song')
active='B';file='B.rpp';tracks={{id='track-B',volume=.5,pan=0}}
check(B.find_session(folder,a)==nil,'Another song unfinished mix does not block a clean song')
check(J.encode(J.read(a..'/snapshot.json'))==before,'Looking up another project leaves original journal unchanged')
local b=journal('B','B.rpp','track-B',20)
check(B.find_session(folder,a).path==b,'Second song finds its own candidate despite foreign global pointer')
active='A';file='A.rpp';tracks={{id='track-A',volume=.5,pan=0}}
check(B.find_session(folder,b).path==a,'Returning to first song restores its original candidate')
check(B.find_session(folder,'').path==a,'Per-project recovery survives a missing global pointer')
local older=journal('older','A.rpp','track-A',5)
local finished=journal('finished','A.rpp','track-A',50,true)
check(B.find_session(folder,older).path==a,'Most recent unfinished candidate wins; finished journals are ignored')
tracks[1].volume=.7
check(B.find_session(folder,b).recovery_changed,'Manual edits still open stale-mix recovery instead of overwriting changes')
tracks[1].volume=.5
local snapshot=J.read(a..'/snapshot.json');snapshot.finished=true;J.write(a..'/snapshot.json',snapshot)
snapshot=J.read(older..'/snapshot.json');snapshot.finished=true;J.write(older..'/snapshot.json',snapshot)
check(B.find_session(folder,a)==nil,'Resolved song has no pending session')
active='B';file='B.rpp';tracks={{id='track-B',volume=.5,pan=0}}
check(B.find_session(folder,a).path==b,'Resolving one song leaves the other unfinished mix available')
local custom=journal('custom-location','custom.rpp','custom-track',70,false,false)
active='custom';file='custom.rpp';tracks={{id='custom-track',volume=.5,pan=0}}
check(B.find_session(folder,custom).path==custom,'Legacy journal outside enumerated folders remains recoverable')
local u1=journal('unsaved-one','','unsaved-A',80)
local u2=journal('unsaved-two','','unsaved-B',90)
active='unsaved-A';file='';tracks={{id='unsaved-A',volume=.5,pan=0}}
check(B.find_session(folder,u2).path==u1,'Unsaved tabs use track GUIDs to distinguish candidates')
active='unsaved-B';tracks={{id='unsaved-B',volume=.5,pan=0}}
check(B.find_session(folder,u1).path==u2,'Second unsaved tab recovers only its own candidate')
tracks={{id='unrelated',volume=.5,pan=0}}
check(B.find_session(folder,u1)==nil,'Unrelated unsaved project has no inherited unfinished mix')
local bad=folder..'/incomplete';assert(os.execute('mkdir -p "'..bad..'"'));created[#created+1]=bad;children[#children+1]='incomplete'
local f=assert(io.open(bad..'/snapshot.json','w'));f:write('{incomplete');f:close()
file='B.rpp';tracks={{id='track-B',volume=.5,pan=0}}
check(B.find_session(folder,bad).path==b,'Unreadable unrelated journal does not block valid recovery')
for _,path in ipairs(created)do os.remove(path..'/snapshot.json');os.remove(path..'/status.json');os.remove(path)end
os.remove(folder)
print(passed..' project-specific mix session checks passed')
