-- Isolated native checks. The recording check captures silent track output,
-- with no hardware inputs and muted output, then restores the user's tab.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local M=dofile(root..'/Scripts/solo_core.lua');local S=M.sections()
assert(R.GetPlayState()==0,'Stop transport before section checks.')
local original=R.EnumProjects(-1,'')
local user={tempo=R.Master_GetTempo(),tracks=R.CountTracks(0),items=R.CountMediaItems(0),armed={}}
local total_markers=R.CountProjectMarkers(0);user.markers=total_markers
for i=0,R.CountTracks(0)-1 do user.armed[i]=R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM')end
local filename=root..'/Tests/Section checks.RPP'
local blank=assert(io.open(filename,'w'))
blank:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n MASTERHWOUT 0 0 1 0 0 0 0 -1\n RECORD_PATH "Section test media"\n <METRONOME 0 0\n VOL 0.25 0.125\n >\n>\n');blank:close()
R.Main_OnCommand(41929,0);R.Main_openProject(filename)
local project=R.EnumProjects(-1,'')
local master=R.GetMasterTrack(0)
R.SetMediaTrackInfo_Value(master,'B_MUTE',1)
local log=assert(io.open(root..'/Tests/section-checks.txt','w'));local total=0
local function check(condition,label)assert(condition,label);total=total+1;log:write('PASS: ',label,'\n');log:flush()end
local finished=false
local function finish(err)
 if finished then return end;finished=true
 S.cancel_watch()
 if R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project)
  if R.GetPlayState()~=0 then M.stop()end
  R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 local valid=R.Master_GetTempo()==user.tempo and R.CountTracks(0)==user.tracks and R.CountMediaItems(0)==user.items
 for i=0,R.CountTracks(0)-1 do valid=valid and user.armed[i]==R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM')end
 local markers=R.CountProjectMarkers(0);valid=valid and markers==user.markers
 if valid then log:write('PASS: User project media, tempo, markers, and arming unchanged\n')else err=(err or '')..' User project state changed.'end
 log:write(err and ('FAIL: '..tostring(err)..'\n')or(total..' section checks passed.\n'));log:close()
 if err then R.ShowMessageBox(tostring(err),'Section checks failed',0)end
end
local tracks,before,endpoint
local ok,err=xpcall(function()
 tracks=M.add_instrument('Scratch guitar + vocal',{'Test guide vocal','Test guide guitar'})
 for _,tr in ipairs(tracks)do
  R.SetMediaTrackInfo_Value(tr,'B_MAINSEND',0);R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',2)
  for lane=0,1 do
   local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
   R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
   R.SetMediaItemInfo_Value(item,'D_LENGTH',lane==0 and 32 or 40)
   R.SetMediaItemInfo_Value(item,'I_FIXEDLANE',lane)
  end
 end
 R.UpdateTimeline();M.audition(0)
 local media=R.CountMediaItems(0)
 local song=S.from_scratch();check(song.s==0 and song.e==32,'Outline uses playing scratch take, excluding longer unused take')
 local verse=S.split(7.2);check(verse.s==8 and verse.e==32 and #S.list()==2,'Transition snaps to nearest bar')
 check(S.find(song.key).e==8,'Existing region identity retained after split')
 S.rename(song.key,'Intro');S.rename(verse.key,'Verse')
 local chorus=S.split(18.2);S.rename(chorus.key,'Chorus')
 check(#S.list()==3 and S.find(chorus.key).s==18,'Multiple named song sections')
 S.set_snap(false);local bridge=S.split(23.125);S.rename(bridge.key,'Bridge')
 check(S.find(bridge.key).s==23.125,'Exact transition position when snap is off')
 check(R.CountMediaItems(0)==media,'Mapping sections never splits or removes recorded audio')
 check(not pcall(S.create,4,10,'Overlap'),'Overlapping sections rejected')
 check(not pcall(S.create,40,40,'Empty'),'Zero-length sections rejected')
 S.select(verse.key)
 local a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
 check(a==8 and b==18 and R.GetToggleCommandStateEx(0,40076)==1,'Selecting a section sets exact punch bounds')
 check(S.prepare_record()==18 and R.GetSetRepeat(-1)==0,'One-pass mode returns section stop position')
 S.set_loop(true);check(S.prepare_record()==nil and R.GetSetRepeat(-1)==1,'Loop mode repeats without auto-stop')
 R.SetProjectMarker3(0,verse.id,true,8,18,'Verse 1',verse.color)
 check(S.active().name=='Verse 1','Native timeline renaming appears in section list')
 S.resize(verse.key,8,17.5);a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
 check(b==17.5 and S.active().e==17.5,'Edited section bounds update recording selection')
 local rows=M.lanes();check(#S.filter_takes(rows)==2,'Full-song takes remain available for section comping')
 M.comp(0)
 for _,tr in ipairs(tracks)do
  local found=false
  for j=0,R.CountTrackMediaItems(tr)-1 do
   local it=R.GetTrackMediaItem(tr,j)
   if math.abs(R.GetMediaItemInfo_Value(it,'D_POSITION')-8)<0.00001 and math.abs(R.GetMediaItemInfo_Value(it,'D_LENGTH')-9.5)<0.02 then found=true end
  end
  check(found,'Keep passage comp follows section bounds across microphones')
 end
 S.full_song();a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
 check(a==b and R.GetSetRepeat(-1)==0 and R.GetToggleCommandStateEx(0,40252)==1 and R.GetCursorPosition()==0,'Full song clears punch/loop bounds and starts at beginning')
 S.select(verse.key);M.loop_bars(4);check(S.mode()=='','Manual passage tools release named-section target')
 S.select(verse.key);S.remove(verse.key);check(not S.find(verse.key) and S.mode()=='','Removing region label releases record target')
 R.Undo_DoUndo2(0);check(S.find(verse.key)~=nil,'Undo restores removed section label')
 S.select(verse.key);R.DeleteProjectMarker(0,verse.id,true)
 check(not pcall(S.prepare_record),'Deleted target cannot silently record the wrong section')
 S.full_song();S.select(chorus.key)
 local key=S.active().key
 R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)
 R.Main_OnCommand(41929,0);R.Main_openProject(filename);project=R.EnumProjects(-1,'')
 check(S.active() and S.active().key==key and S.active().name=='Chorus','Section identity and recording target survive save/reopen')
 S.full_song()
 -- Use an empty gap after the guide as an isolated 0.4-second output recording.
 local test=S.create(42,42.4,'Recording check');S.select(test.key);S.set_loop(false)
 tracks=M.tracks();before={}
 for i,tr in ipairs(tracks)do before[i]=R.CountTrackMediaItems(tr)end
 M.arm=function()
  R.ClearAllRecArmed()
  for _,tr in ipairs(tracks)do
   R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',-1)
   R.SetMediaTrackInfo_Value(tr,'I_RECMODE',1) -- Record silent stereo track output.
   R.SetMediaTrackInfo_Value(tr,'I_RECMON',0)
   R.SetMediaTrackInfo_Value(tr,'I_RECARM',1)
  end
 end
 endpoint=test.e
end,debug.traceback)
if not ok then finish(err);return end
if R.Audio_IsRunning()==0 then
 log:write('SKIP: Live recording needs a running audio device.\n');finish();return
end
local ready=R.time_precise()+0.5
local deadline=ready+10
local recording_started=false
local function poll()
 if not recording_started then
  if R.time_precise()<ready then R.defer(poll);return end
  local ok,err=xpcall(function()M.record();check(R.GetPlayState()&4~=0,'Single-pass recording starts')end,debug.traceback)
  if not ok then finish(err);return end
  recording_started=true;R.defer(poll);return
 end
 if R.GetPlayStateEx(project)&4~=0 then
  if R.time_precise()>deadline then finish('Section recording did not stop automatically.');return end
  R.defer(poll);return
 end
 local ok,err=xpcall(function()
  check(R.GetExtState(M.ns,'section_record_job')=='','Stop helper finishes without the panel running')
  for i,tr in ipairs(tracks)do
   check(R.CountTrackMediaItems(tr)>before[i],'Single pass keeps recorded media on each track')
   local found=false
   for j=0,R.CountTrackMediaItems(tr)-1 do
    local it=R.GetTrackMediaItem(tr,j)
    local s=R.GetMediaItemInfo_Value(it,'D_POSITION');local e=s+R.GetMediaItemInfo_Value(it,'D_LENGTH')
    if math.abs(s-42)<0.02 and math.abs(e-endpoint)<0.02 then found=true end
   end
   check(found,'Native punch keeps exact section start and end')
  end
 end,debug.traceback)
 finish(not ok and err or nil)
end
R.defer(poll)
