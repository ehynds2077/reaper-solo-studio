-- Silent native pre-roll test: generated guide tone is metered internally;
-- hardware outputs and the test metronome are muted, and no inputs are recorded.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local M=dofile(root..'/Scripts/solo_core.lua');local S=M.sections()
assert(R.GetPlayState()==0,'Stop transport before checking the musical lead-in.')
local original=R.EnumProjects(-1,'');local old_preroll=R.GetToggleCommandStateEx(0,41819)
local old={items=R.CountMediaItems(0),tracks=R.CountTracks(0),tempo=R.Master_GetTempo(),markers=R.CountProjectMarkers(0),arm={}}
for i=0,R.CountTracks(0)-1 do old.arm[i]=R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM')end
local filename=root..'/Tests/Lead-in checks.RPP'
local file=assert(io.open(filename,'w'));file:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n MASTERHWOUT 0 0 1 0 0 0 0 -1\n RECORD_PATH "Lead-in test media"\n <METRONOME 7 2\n VOL 0 0\n >\n>\n');file:close()
R.Main_OnCommand(41929,0);R.Main_openProject(filename)
local project=R.EnumProjects(-1,'');local master=R.GetMasterTrack(0)
for i=0,R.GetTrackNumSends(master,1)-1 do R.SetTrackSendInfo_Value(master,1,i,'B_MUTE',1)end
local log=assert(io.open(root..'/Tests/leadin-checks.txt','w'));local total=0;local done=false
local function check(ok,label)assert(ok,label);total=total+1;log:write('PASS: '..label..'\n');log:flush()end
local function finish(err)
 if done then return end;done=true
 R.SelectProjectInstance(project);M.stop()
 if R.GetToggleCommandStateEx(0,41819)~=old_preroll then R.Main_OnCommand(41819,0)end
 R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0);R.SelectProjectInstance(original)
 local same=R.CountMediaItems(0)==old.items and R.CountTracks(0)==old.tracks and R.Master_GetTempo()==old.tempo and R.CountProjectMarkers(0)==old.markers
 for i=0,R.CountTracks(0)-1 do same=same and R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM')==old.arm[i]end
 log:write(same and 'PASS: User song and recording arming preserved\n'or'FAIL: User state changed\n')
 log:write(err and 'FAIL: '..tostring(err)..'\n'or total..' native musical lead-in checks passed.\n');log:close()
 if err then R.ShowMessageBox(tostring(err),'Lead-in checks failed',0)end
end
local guide,tracks,click_before
local ok,err=xpcall(function()
 R.InsertTrackAtIndex(0,false);guide=R.GetTrack(0,0)
 R.GetSetMediaTrackInfo_String(guide,'P_NAME','Silent test guide',true)
 local item=R.AddMediaItemToTrack(guide);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/lead-in-tone.wav'))
 R.SetMediaItemInfo_Value(item,'D_LENGTH',16)
 tracks=M.add_instrument('Test record set',{'Test output 1','Test output 2'})
 for _,tr in ipairs(tracks)do R.SetMediaTrackInfo_Value(tr,'B_MAINSEND',0)end
 M.arm=function()
  R.ClearAllRecArmed()
  for _,tr in ipairs(tracks)do
   R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',-1);R.SetMediaTrackInfo_Value(tr,'I_RECMODE',1)
   R.SetMediaTrackInfo_Value(tr,'I_RECMON',0);R.SetMediaTrackInfo_Value(tr,'I_RECARM',1)
  end
 end
 local row=S.create(8,9,'Test punch');S.select(row.key);S.set_loop(false)
 _,click_before=R.get_config_var_string('projmetrov1')
 local _,measures=R.get_config_var_string('prerollmeas');check(tonumber(measures)==2,'Native pre-roll is two bars')
end,debug.traceback)
if not ok then finish(err);return end
local phase='pass';local negative=false;local looped=false;local prior_pos
local ready=R.time_precise()+0.5;local began;local music,dimmed,restored=false,false,false;local last_log=-1
local function next_phase(name)
 phase=name;began=nil;ready=R.time_precise()+0.3;last_log=-1
 if name=='loop' then S.set_loop(true)
 elseif name=='early' then S.set_loop(false)
 elseif name=='start' then local row=S.create(0,1,'Start of song');S.select(row.key);S.set_loop(false)end
end
local function poll()
 local ok,err=xpcall(function()
  local now=R.time_precise()
  if not began then if now<ready then R.defer(poll);return end;M.record();began=now;R.defer(poll);return end
  local state=R.GetPlayStateEx(project);local pos=R.GetPlayPositionEx(project)
  local peak=R.Track_GetPeakInfo(guide,0);local gain=R.GetTrackSendInfo_Value(master,1,0,'D_VOL')
  if now-began>last_log+0.25 then log:write(string.format('%s t=%.2f state=%d pos=%.3f peak=%.4f gain=%.4f\n',phase,now-began,state,pos,peak,gain));log:flush();last_log=now-began end
  if phase=='loop' then
   if prior_pos and prior_pos>8.8 and pos<8.2 then looped=true end;prior_pos=pos
   assert(state&4~=0,'Loop recording stopped unexpectedly')
   if looped and pos>8.3 then
    check(math.abs(gain-1)<0.00001,'Loop passes keep normal gain after the initial lead-in')
    check(state&4~=0,'Loop recording continues after the first section boundary')
    M.stop();next_phase('early')
   else assert(now-began<8,'Loop did not repeat')end
   R.defer(poll);return
  elseif phase=='early' then
   if now-began>1 then
    check(math.abs(gain-10^(-6/20))<0.00001,'An early stop begins from dimmed playback')
    -- Native Stop, not the panel helper: its watcher must restore the output.
    R.Main_OnCommand(40667,0);phase='stopped';ready=now+0.2
   end
   R.defer(poll);return
  elseif phase=='stopped' then
   if now<ready then R.defer(poll);return end
   check(math.abs(gain-1)<0.00001,'Native Stop during lead-in restores playback gain')
   next_phase('start');R.defer(poll);return
  elseif phase=='start' then
   negative=negative or pos<0
   if state~=0 then assert(now-began<7,'Song-start recording did not finish');R.defer(poll);return end
   check(negative and now-began>4,'Starting at bar one still has a two-bar click lead-in')
   check(math.abs(gain-1)<0.00001,'Song-start lead-in leaves playback gain unchanged')
   finish();return
  end
  if pos>=4 and pos<7.9 and peak>0.005 then music=true;dimmed=dimmed or math.abs(gain-10^(-6/20))<0.00001 end
  if pos>8.1 and pos<8.9 and math.abs(gain-1)<0.00001 then restored=true end
  if state~=0 then
   assert(now-began<12,'Native section recording did not finish within the expected lead-in and section.')
   R.defer(poll);return
  end
  check(music,'Existing guide audio plays during pre-roll')
  check(dimmed,'Playback hardware sends are 6 dB quieter during the lead-in')
  check(restored,'Normal playback gain returns at the punch-in')
  check(now-began<6.5,'Two-bar count-in and musical lead-in run together without doubling the wait')
  check(math.abs(gain-1)<0.00001,'Playback gain restored when recording ends')
  for _,tr in ipairs(tracks)do
   local found=false
   for j=0,R.CountTrackMediaItems(tr)-1 do local item=R.GetTrackMediaItem(tr,j)
    local a=R.GetMediaItemInfo_Value(item,'D_POSITION');local b=a+R.GetMediaItemInfo_Value(item,'D_LENGTH')
    if math.abs(a-8)<0.02 and math.abs(b-9)<0.02 then found=true end
   end
   check(found,'Recorded item stays within the selected section')
  end
  local _,v=R.get_config_var_string('projmetrov1');check(v==click_before,'Metronome level was not changed by playback dimming')
  next_phase('loop');R.defer(poll)
 end,debug.traceback)
 if not ok then finish(err)end
end
R.defer(poll)
