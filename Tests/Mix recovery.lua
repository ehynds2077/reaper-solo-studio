-- A saved project keeps ownership after track edits; restarting never changes audio.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua')
local path=os.tmpname();os.remove(path);assert(os.execute('mkdir -p "'..path..'"'))
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local project,file,play='song','song.rpp',0
local original={id='original',volume=.5,pan=.2,fx={'owned'}}
local extra={id='new guitar',volume=.8,pan=-.5,fx={'user effect'}}
local tracks={original}
reaper={
 EnumProjects=function()return project,file end,CountTracks=function()return #tracks end,
 GetTrack=function(_,i)return tracks[i+1]end,GetTrackGUID=function(tr)return tr.id end,
 GetMediaTrackInfo_Value=function(tr,key)return key=='D_VOL'and tr.volume or tr.pan end,
 GetProjectStateChangeCount=function()return 10 end,GetPlayState=function()return play end,
 TrackFX_GetCount=function(tr)return #tr.fx end,TrackFX_GetFXGUID=function(tr,i)return tr.fx[i+1]end,
}
-- All mutation, transport, rendering and undo APIs are deliberately absent.
local B=dofile(root..'/Scripts/solo_mix_bridge.lua')
local function snapshot()
 local s={original=J.array({{id='original',volume=1,pan=0}}),expected={original={volume=.5,pan=.2}},
  owned=J.array({{track='original',id='owned'}}),bounds={0,8},mode='candidate',project_path='song.rpp',finished=false}
 J.write(path..'/snapshot.json',s);return s
end
snapshot()
local s=B.recover(path)
check(s and not s.recovery_changed,'Unchanged project resumes normal review')
tracks={extra,original};s=B.recover(path)
check(s and s.project==project and s.recovery_changed,'Added and reordered tracks still belong to the same project')
check(not pcall(B.guard,s,true,true),'Outdated review cannot overwrite edits or claim old measurements')
B.archive_current(s)
local archived=J.read(path..'/snapshot.json')
check(archived.finished and archived.resolution=='continued_from_current_mix','Fresh start finishes old journal explicitly')
check(#archived.original==1 and #archived.owned==1 and archived.expected.original.volume==.5,'Archive retains original snapshot and effect ownership')
check(extra.volume==.8 and extra.pan==-.5 and original.volume==.5 and #original.fx==1,'Fresh start preserves new tracks and current sound without native writes')
check(B.recover(path)==nil,'Archived review does not block the next session')
snapshot();tracks={original};original.volume=.7;s=B.recover(path)
check(s and s.recovery_changed,'Manual fader edits offer fresh start instead of foreign-project error')
original.volume=.5;original.fx={};s=B.recover(path)
check(s and s.recovery_changed,'Removed effects offer safe recovery')
original.fx={'owned'};tracks={extra};s=B.recover(path)
check(s and s.recovery_changed,'Deleted original track does not strand a saved project')
B.archive_current(s)
check(J.read(path..'/snapshot.json').finished,'Can archive obsolete session after track deletion')
snapshot();file='different.rpp'
check(B.recover(path)==nil,'Actual other project remains protected even with matching GUIDs')
local unsaved=snapshot();unsaved.project_path='';J.write(path..'/snapshot.json',unsaved);file=''
check(B.recover(path)==nil,'Unrelated unsaved project is not mistaken for owner')
tracks={original,extra};s=B.recover(path)
check(s and s.recovery_changed,'Unsaved owner can recover after adding tracks')
file='song.rpp';snapshot();s=B.recover(path);project='other tab'
check(not pcall(B.archive_current,s)and not J.read(path..'/snapshot.json').finished,'Project switch cannot archive another active session')
project='song'
for _,transport in ipairs({1,4,5})do
 play=transport;check(not pcall(B.archive_current,s)and not J.read(path..'/snapshot.json').finished,'Fresh setup waits for stopped transport '..transport)
end
os.remove(path..'/snapshot.json');os.remove(path)
print(passed..' mix recovery checks passed')
