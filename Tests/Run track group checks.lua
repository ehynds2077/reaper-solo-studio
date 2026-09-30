-- Native group edits and Undo/Redo in a silent disposable project.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
if R.GetExtState('SoloStudio_v1','panel_open')=='1'or R.GetAllProjectPlayStates()~=0 then
 R.ShowMessageBox('Close Solo Studio and stop transport before running these isolated checks.','Track group checks',0);return
end
local filename=root..'/Tests/Track group checks.RPP'
local log=assert(io.open(root..'/Tests/track-group-checks.txt','w'))
local count=0
local function check(value,label)assert(value,label);count=count+1;log:write('PASS: '..label..'\n');log:flush()end
local original=R.EnumProjects(-1,'');local project
local original_chunks={}
local ok,err=xpcall(function()
 assert(R.GetPlayState()==0,'Stop transport before running the isolated checks.')
 for i=0,R.CountTracks(original)-1 do
  local track=R.GetTrack(original,i);local success,chunk=R.GetTrackStateChunk(track,'',false);assert(success)
  original_chunks[R.GetTrackGUID(track)]=chunk
 end
 local f=assert(io.open(filename,'w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(filename);project=R.EnumProjects(-1,'');assert(project~=original)
 R.SetMediaTrackInfo_Value(R.GetMasterTrack(project),'B_MUTE',1)
 local tracks={};for i=0,2 do R.InsertTrackAtIndex(i,false);tracks[#tracks+1]=R.GetTrack(project,i)end
 local M=dofile(root..'/Scripts/solo_core.lua');local T=dofile(root..'/Scripts/solo_tracks.lua')(M)
 local names={'Kick','Snare','Guitar'}
 for i,track in ipairs(tracks)do R.GetSetMediaTrackInfo_String(track,'P_NAME',names[i],true)end
 M.put('sets','drums\nguitar');M.put('active','drums');M.put('set.drums.name','Drums')
 M.put('set.drums.tracks',R.GetTrackGUID(tracks[1])..'\n'..R.GetTrackGUID(tracks[2]))
 M.put('set.guitar.name','Guitar');M.put('set.guitar.tracks',R.GetTrackGUID(tracks[3]))
 local function drums()return T.groups()[1]end
 R.SetMediaTrackInfo_Value(tracks[2],'D_VOL',.5)
 R.SetMediaTrackInfo_Value(tracks[1],'D_PAN',-.5);R.SetMediaTrackInfo_Value(tracks[2],'D_PAN',.5)
 R.SetMediaTrackInfo_Value(tracks[3],'I_PANMODE',6)
 R.SetMediaTrackInfo_Value(tracks[3],'D_DUALPANL',-.4);R.SetMediaTrackInfo_Value(tracks[3],'D_DUALPANR',.4)
 R.Undo_OnStateChange2(project,'Native group test setup')
 local function history(redo)
  M.history(redo);assert(R.CountTracks(project)==3,'Undo changed the fixture track count')
  for i=1,3 do tracks[i]=R.GetTrack(project,i-1)end
 end
 T.set_volume(drums(),-6,project)
 local gain=10^(-6/20)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[1],'D_VOL')-gain)<1e-8 and math.abs(R.GetMediaTrackInfo_Value(tracks[2],'D_VOL')-gain*.5)<1e-8,'Native linked faders preserve relative gain')
 history(false)
 check(R.GetMediaTrackInfo_Value(tracks[1],'D_VOL')==1 and R.GetMediaTrackInfo_Value(tracks[2],'D_VOL')==.5,'Native Undo restores both faders')
 T.set_pan(drums(),.25,project)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[1],'D_PAN')+.25)<1e-8 and math.abs(R.GetMediaTrackInfo_Value(tracks[2],'D_PAN')-.75)<1e-8,'Native linked pan preserves microphone spacing')
 history(false)
 local left,right=R.GetMediaTrackInfo_Value(tracks[1],'D_PAN'),R.GetMediaTrackInfo_Value(tracks[2],'D_PAN')
 check(math.abs(left+.5)<1e-8 and math.abs(right-.5)<1e-8,string.format('Native Undo restores linked pan positions (%.12g / %.12g)',left,right))
 history(true)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[1],'D_PAN')+.25)<1e-8,'Native Redo reapplies linked pan')
 T.set_pan(drums(),1,project)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[1],'D_PAN'))<1e-8 and math.abs(R.GetMediaTrackInfo_Value(tracks[2],'D_PAN')-1)<1e-8,'Native pan stops at the edge without collapsing the stereo image')
 T.set_pan(T.groups()[2],.3,project)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[3],'D_DUALPANL')+.1)<1e-8 and math.abs(R.GetMediaTrackInfo_Value(tracks[3],'D_DUALPANR')-.7)<1e-8 and R.GetMediaTrackInfo_Value(tracks[3],'I_PANMODE')==6,'Native dual-pan endpoints move together without changing pan mode')
 history(false)
 check(math.abs(R.GetMediaTrackInfo_Value(tracks[3],'D_DUALPANL')+.4)<1e-8 and math.abs(R.GetMediaTrackInfo_Value(tracks[3],'D_DUALPANR')-.4)<1e-8,'Native Undo restores both dual-pan endpoints')
 T.rename_group(drums(),'Live kit',project)
 check(M.sets()[1].name=='Live kit'and M.track_name(tracks[1])=='Kick','Native group name updates without renaming microphones')
 history(false);check(M.sets()[1].name=='Drums','Native Undo restores the group label')
 history(true);check(M.sets()[1].name=='Live kit','Native Redo restores the renamed group')
 R.SetMediaTrackInfo_Value(tracks[2],'B_MUTE',1)
 R.Undo_OnStateChange2(project,'Native mute test setup')
 T.toggle_mute(drums(),project)
 check(R.GetMediaTrackInfo_Value(tracks[1],'B_MUTE')==1 and R.GetMediaTrackInfo_Value(tracks[3],'B_MUTE')==0,'Native group mute affects only its members')
 T.toggle_mute(drums(),project)
 check(R.GetMediaTrackInfo_Value(tracks[1],'B_MUTE')==0 and R.GetMediaTrackInfo_Value(tracks[2],'B_MUTE')==1,'Native unmute restores previously muted microphones')
 history(false);check(R.GetMediaTrackInfo_Value(tracks[1],'B_MUTE')==1,'Native Undo restores group mute')
 T.toggle_mute(drums(),project)
 check(R.GetMediaTrackInfo_Value(tracks[1],'B_MUTE')==0 and R.GetMediaTrackInfo_Value(tracks[2],'B_MUTE')==1,'Mute metadata survives native Undo')
 R.Main_SaveProjectEx(project,filename,8)
 local f=assert(io.open(filename,'r'));local saved=f:read('*a');f:close()
 check(saved:find('Live kit',1,true)~=nil,'Renamed group persists in the saved project')
end,debug.traceback)
if project and R.ValidatePtr(project,'ReaProject*')then
 R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)
end
R.SelectProjectInstance(original)
local preserved=true;local found=0
for i=0,R.CountTracks(original)-1 do
 local track=R.GetTrack(original,i);local success,chunk=R.GetTrackStateChunk(track,'',false)
 preserved=preserved and success and original_chunks[R.GetTrackGUID(track)]==chunk;found=found+1
end
local expected=0;for _ in pairs(original_chunks)do expected=expected+1 end
if preserved and found==expected then log:write('PASS: User project track contents preserved exactly\n')else log:write('FAIL: User project preservation mismatch\n')end
if ok then log:write(count..' native group checks passed.\n')else log:write('FAIL: '..tostring(err)..'\n')end
log:close()
-- Show the requested view through REAPER's public ReaScript launch API.
R.SetExtState('SoloStudio_v1','panel_view','tracks',true)
dofile(root..'/Launcher/launch.lua')
