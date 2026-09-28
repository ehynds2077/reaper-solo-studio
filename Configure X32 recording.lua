-- Configure Ethan's empty starter project. Run from REAPER's Actions list.
-- Refuses other projects and projects containing media. All changes are undoable.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(root..'/Scripts/solo_core.lua')
local project,path=R.EnumProjects(-1,'')
assert(path==root..'/Starter song/Starter song.RPP','Open the Solo Studio Starter song first.')
assert(R.GetPlayState()==0,'Stop transport before configuring inputs.')
assert(R.CountMediaItems(0)==0,'This setup is only for the empty starter project.')
assert(R.GetNumAudioInputs()>=11,'Connect the X32 with at least 11 USB inputs enabled.')

local function track(name)
  for i=0,R.CountTracks(0)-1 do
    local t=R.GetTrack(0,i)
    if M.track_name(t)==name then return t end
  end
end
local function set(name)
  for _,s in ipairs(M.sets()) do if s.name==name then return s.id end end
end
local drums=assert(set('Drums'),'Missing drum recording set.')
local electric=assert(set('Guitar') or set('Electric guitar'),'Missing guitar recording set.')
local kick=assert(track('Kick'))
local top=assert(track('Snare') or track('Snare top'))
local ohl=assert(track('Overhead L'))
local ohr=assert(track('Overhead R'))
local old={ [kick]=true,[top]=true,[ohl]=true,[ohr]=true }
-- Reuse the existing dedicated drum media-edit group after checking its scope.
local group=math.floor(R.GetSetTrackGroupMembership(kick,'MEDIA_EDIT_LEAD',0,0))
assert(group~=0 and (group & (group-1))==0,'Expected one drum media-edit group.')
for i=0,R.CountTracks(0)-1 do
  local t=R.GetTrack(0,i)
  local membership=math.floor(R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_LEAD',0,0)) |
    math.floor(R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_FOLLOW',0,0))
  local _,tag=R.GetSetMediaTrackInfo_String(t,'P_EXT:SoloStudioX32Drum','',false)
  assert((membership & group)==0 or old[t] or tag=='1','Drum edit group includes another instrument.')
end

-- Capture the current saved project before changing any tracks.
local backup=root..'/Backups/before-x32-recording'
R.RecursiveCreateDirectory(backup,0)
local backupfile=backup..'/Starter song '..os.date('%Y%m%d-%H%M%S')..'.RPP'
R.Main_SaveProject(0,false)
local src=assert(io.open(path,'rb'));local data=src:read('*a');src:close()
local dst=assert(io.open(backupfile,'wb'));dst:write(data);dst:close()

local drumtracks={}
local specifications={
 {'Kick',1}, {'Snare top',2}, {'Snare bottom',3}, {'Tom 1',4},
 {'Tom 2',5}, {'Hi-hat',6}, {'Overhead L',7}, {'Overhead R',8}, {'Ride',11}
}
M.edit('configure X32 drum and guitar recording',function()
  R.GetSetMediaTrackInfo_String(top,'P_NAME','Snare top',true)
  for _,spec in ipairs(specifications) do
    local t=track(spec[1])
    if not t then
      -- Insert close mics before the overhead pair; ride follows overhead R.
      local index=spec[1]=='Ride' and R.GetMediaTrackInfo_Value(ohr,'IP_TRACKNUMBER')
        or R.GetMediaTrackInfo_Value(ohl,'IP_TRACKNUMBER')-1
      R.InsertTrackAtIndex(index,true);t=R.GetTrack(0,index)
      R.GetSetMediaTrackInfo_String(t,'P_NAME',spec[1],true)
    end
    drumtracks[#drumtracks+1]=t
    R.GetSetMediaTrackInfo_String(t,'P_EXT:SoloStudioX32Drum','1',true)
    R.SetTrackColor(t,R.ColorToNative(190,151,196)|0x1000000)
    R.SetMediaTrackInfo_Value(t,'I_RECINPUT',spec[2]-1)
    R.SetMediaTrackInfo_Value(t,'I_RECMODE',0)
    R.SetMediaTrackInfo_Value(t,'I_RECMON',0)
    R.SetMediaTrackInfo_Value(t,'C_BEATATTACHMODE',0)
    R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_LEAD',group,group)
    R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_FOLLOW',group,group)
  end
  R.SetMediaTrackInfo_Value(ohl,'D_PAN',-1)
  R.SetMediaTrackInfo_Value(ohr,'D_PAN',1)
  M.prepare(drumtracks)
  local ids={};for _,t in ipairs(drumtracks) do ids[#ids+1]=R.GetTrackGUID(t) end
  M.put('set.'..drums..'.tracks',table.concat(ids,'\n'))

  local guitar=assert(track('Guitar') or track('Electric guitar'))
  R.GetSetMediaTrackInfo_String(guitar,'P_NAME','Electric guitar',true)
  M.put('set.'..electric..'.name','Electric guitar')
  R.SetMediaTrackInfo_Value(guitar,'I_RECMON',0)
  R.SetMediaTrackInfo_Value(guitar,'I_RECMODE',0)
  if not set('Acoustic guitar') then
    local index=R.GetMediaTrackInfo_Value(guitar,'IP_TRACKNUMBER')
    R.InsertTrackAtIndex(index,true);local acoustic=R.GetTrack(0,index)
    R.GetSetMediaTrackInfo_String(acoustic,'P_NAME','Acoustic guitar',true)
    R.SetMediaTrackInfo_Value(acoustic,'I_RECINPUT',-1)
    R.SetMediaTrackInfo_Value(acoustic,'I_RECMON',0)
    R.SetMediaTrackInfo_Value(acoustic,'I_RECMODE',0)
    R.SetMediaTrackInfo_Value(acoustic,'C_BEATATTACHMODE',0)
    R.SetTrackColor(acoustic,R.ColorToNative(202,155,103)|0x1000000)
    M.prepare({acoustic})
    local id=R.genGuid()
    M.put('sets',M.get('sets')..'\n'..id)
    M.put('set.'..id..'.name','Acoustic guitar')
    M.put('set.'..id..'.tracks',R.GetTrackGUID(acoustic))
  end
  M.choose_set(drums)
  R.ClearAllRecArmed()
  for _,t in ipairs(drumtracks) do R.SetMediaTrackInfo_Value(t,'I_RECARM',1) end
  -- Existing two-bar count-in, tempo, click, guitar FX and master routing remain.
  if R.GetToggleCommandStateEx(0,1156)==0 then R.Main_OnCommand(1156,0) end
  R.SetEditCurPos(0,false,false)
end)

local report={ 'X32 recording setup verified', 'Project: '..path,
  'Device inputs: '..R.GetNumAudioInputs(), 'Backup: '..backupfile }
assert(#M.tracks()==9,'Drum set must contain all nine microphones.')
local armed=0
for i=0,R.CountTracks(0)-1 do
  local t=R.GetTrack(0,i)
  if R.GetMediaTrackInfo_Value(t,'I_RECARM')==1 then armed=armed+1 end
end
assert(armed==9,'Only the nine drum microphones should be armed.')
for i,t in ipairs(drumtracks) do
  assert(R.GetMediaTrackInfo_Value(t,'I_RECINPUT')==specifications[i][2]-1)
  assert(R.GetMediaTrackInfo_Value(t,'I_RECMON')==0)
  assert(R.GetMediaTrackInfo_Value(t,'I_FREEMODE')==2)
  assert((math.floor(R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_LEAD',0,0)) & group)~=0)
  assert((math.floor(R.GetSetTrackGroupMembership(t,'MEDIA_EDIT_FOLLOW',0,0)) & group)~=0)
  report[#report+1]=string.format('%s: USB %d, armed, monitoring off, grouped fixed lanes',M.track_name(t),specifications[i][2])
end
for _,name in ipairs({'Electric guitar','Acoustic guitar'}) do
  assert(set(name),'Missing '..name..' recording set.')
  local t=assert(track(name))
  assert(R.GetMediaTrackInfo_Value(t,'I_RECMON')==0)
  report[#report+1]=name..': recording set ready; input '..R.GetMediaTrackInfo_Value(t,'I_RECINPUT')
end
assert(R.CountMediaItems(0)==0,'Setup must not create recordings.')
R.Main_SaveProject(0,false)
local f=assert(io.open(root..'/Tests/x32-setup.txt','w'));f:write(table.concat(report,'\n')..'\n');f:close()
R.Main_OnCommand(40913,0) -- Vertical scroll selected tracks into view.
local command=R.NamedCommandLookup('_RS64316da5bd79c2a658a42b415c6e5cdb22f9d602')
if command~=0 then R.Main_OnCommand(command,0) end
