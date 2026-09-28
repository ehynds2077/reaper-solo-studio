local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
assert(R.GetPlayState()==0,'Stop transport before isolated tempo checks.')
local previous=R.EnumProjects(-1,'')
local original={tempo=R.Master_GetTempo(),items=R.CountMediaItems(0),tracks=R.CountTracks(0),armed={}}
local _,oldvolume=R.get_config_var_string('projmetrov1');original.volume=oldvolume
for i=0,R.CountTracks(0)-1 do original.armed[i]=R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM') end
R.Main_OnCommand(41929,0)
local project=R.EnumProjects(-1,'')
local master=R.GetMasterTrack(0)
for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i) end
local log=assert(io.open(dir..'/tempo-checks.txt','w'))
local module=R.GetResourcePath()..'/Scripts/Solo Studio/solo_tempo.lua'
local T=dofile(module)
local total=0
local function check(condition,name)
  assert(condition,name);total=total+1;log:write('PASS: ',name,'\n')
end
local ok,err=xpcall(function()
  R.InsertTrackAtIndex(0,true)
  local track=R.GetTrack(0,0)
  R.SetMediaTrackInfo_Value(track,'C_BEATATTACHMODE',0)
  local item=R.AddMediaItemToTrack(track)
  R.SetMediaItemInfo_Value(item,'D_POSITION',3.25)
  R.SetMediaItemInfo_Value(item,'D_LENGTH',7.5)
  for _,bpm in ipairs({20,73.5,120,187,300}) do
    T.set_bpm(bpm);check(math.abs(T.bpm()-bpm)<0.00001,'Tempo '..bpm..' BPM')
  end
  check(R.GetMediaItemInfo_Value(item,'D_POSITION')==3.25 and R.GetMediaItemInfo_Value(item,'D_LENGTH')==7.5,'Seconds-based recording position and length retained')
  for _,value in ipairs({-1,0,301,math.huge}) do check(not pcall(T.set_bpm,value),'Reject invalid tempo '..value) end
  local oldplay=R.GetPlayState
  R.GetPlayState=function()return 4 end
  local prevented=not pcall(T.set_bpm,150)
  R.GetPlayState=oldplay
  check(prevented and T.bpm()==300,'Tempo change blocked while recording (guard simulation)')
  local _,a=R.get_config_var_string('projmetrov1')
  local _,b=R.get_config_var_string('projmetrov2')
  local ratio=tonumber(b)/tonumber(a)
  for _,db in ipairs({-60,-36,-24,-12,-6,0}) do
    T.set_click_db(db)
    check(math.abs(T.click_db()-db)<0.02,'Native click volume '..db..' dB')
    local _,v1=R.get_config_var_string('projmetrov1');local _,v2=R.get_config_var_string('projmetrov2')
    check(math.abs(tonumber(v2)/tonumber(v1)-ratio)<0.00001,'Preserve relative beat volume at '..db..' dB')
    check(math.abs(T.position_db(T.volume_position())-T.click_db())<0.00001,'Volume slider readback '..db..' dB')
  end
  T.set_volume(0);check(T.click_db()==-math.huge and T.volume_position()==0,'Click mute endpoint')
  T.set_click_db(-12);check(math.abs(T.click_db()+12)<0.02,'Unmute click')
  check(not pcall(T.set_click_db,1) and not pcall(T.set_volume,-1),'Reject invalid click gain')
  T.set_bpm(97.5);T.set_click_db(-18)
  local tempo,volume=T.bpm(),T.click_db()
  R.Main_SaveProjectEx(project,dir..'/Tempo checks.RPP',8)
  R.Main_OnCommand(40860,0)
  R.Main_OnCommand(41929,0)
  R.Main_openProject(dir..'/Tempo checks.RPP')
  project=R.EnumProjects(-1,'')
  check(math.abs(T.bpm()-tempo)<0.00001 and math.abs(T.click_db()-volume)<0.00001,'Tempo and click volume survive save/reopen')
  R.SetTempoTimeSigMarker(0,-1,4,-1,-1,110,4,4,false)
  check(not T.tempo_enabled() and not pcall(T.set_bpm,120),'Protect existing tempo map')
  check(R.CountTracks(0)==1 and R.CountMediaItems(0)==1,'Controls add no tracks or media')
  log:write(total,' native checks passed.\n')
end,debug.traceback)
if not ok then log:write('FAIL: ',err,'\n') end
R.Main_SaveProjectEx(project,dir..'/Tempo checks.RPP',8)
R.Main_OnCommand(40860,0)
R.SelectProjectInstance(previous)
check(R.Master_GetTempo()==original.tempo and R.CountMediaItems(0)==original.items and R.CountTracks(0)==original.tracks,'User project tempo and media unchanged')
local _,volume=R.get_config_var_string('projmetrov1')
check(volume==original.volume,'User click volume unchanged')
for i=0,R.CountTracks(0)-1 do assert(original.armed[i]==R.GetMediaTrackInfo_Value(R.GetTrack(0,i),'I_RECARM')) end
check(true,'User record arming unchanged')
log:close()
if not ok then error(err) end
