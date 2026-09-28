-- Prepare a dedicated guide performance while retaining final instrument tracks.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(root..'/Scripts/solo_core.lua')
local project,path=R.EnumProjects(-1,'')
assert(path==root..'/Starter song/Starter song.RPP','Open the configured Starter song first.')
assert(R.GetPlayState()==0,'Stop transport before preparing the scratch tracks.')
assert(R.GetNumAudioInputs()>=15,'Connect the X32 with USB input 15 enabled.')
local function find(name)
  for i=0,R.CountTracks(0)-1 do
    local t=R.GetTrack(0,i)
    if M.track_name(t)==name then return t end
  end
end
local vocal=assert(find('Vocals'),'Missing final vocal track.')
local guitar=assert(find('Electric guitar'),'Missing final guitar track.')
R.Main_SaveProject(0,false)
local backup=root..'/Backups/before-scratch-recording'
R.RecursiveCreateDirectory(backup,0)
local f=assert(io.open(path,'rb'));local previous=f:read('*a');f:close()
local b=assert(io.open(backup..'/Starter song '..os.date('%Y%m%d-%H%M%S')..'.RPP','wb'));b:write(previous);b:close()
local tracks={}
local specs={{'Scratch vocal',9},{'Scratch guitar',15}}
M.edit('prepare scratch vocal and guitar inputs',function()
  for i,spec in ipairs(specs) do
    local t=find(spec[1])
    if not t then
      R.InsertTrackAtIndex(i-1,true);t=R.GetTrack(0,i-1)
      R.GetSetMediaTrackInfo_String(t,'P_NAME',spec[1],true)
      R.SetTrackColor(t,R.ColorToNative(103,178,166)|0x1000000)
      R.SetMediaTrackInfo_Value(t,'C_BEATATTACHMODE',0)
    end
    tracks[i]=t
    R.SetMediaTrackInfo_Value(t,'I_RECINPUT',spec[2]-1)
    R.SetMediaTrackInfo_Value(t,'I_RECMON',0)
    R.SetMediaTrackInfo_Value(t,'I_RECMODE',0)
  end
  -- The same hardware inputs are ready when the guide is replaced with finals.
  R.SetMediaTrackInfo_Value(vocal,'I_RECINPUT',8)
  R.SetMediaTrackInfo_Value(guitar,'I_RECINPUT',14)
  R.SetMediaTrackInfo_Value(vocal,'I_RECMON',0)
  R.SetMediaTrackInfo_Value(guitar,'I_RECMON',0)
  M.select_tracks(tracks)
end)
local id=M.capture('Scratch guitar + vocal')
M.choose_set(id)
M.arm()
local armed=0
for i=0,R.CountTracks(0)-1 do
  local t=R.GetTrack(0,i)
  if R.GetMediaTrackInfo_Value(t,'I_RECARM')==1 then
    armed=armed+1;assert(t==tracks[1] or t==tracks[2],'Unexpected armed track.')
  end
end
assert(armed==2 and #M.tracks()==2,'Both scratch tracks must be armed.')
for i,t in ipairs(tracks) do
  assert(R.GetMediaTrackInfo_Value(t,'I_RECINPUT')==specs[i][2]-1)
  assert(R.GetMediaTrackInfo_Value(t,'I_RECMON')==0)
  assert(R.GetMediaTrackInfo_Value(t,'I_FREEMODE')==2)
end
local group=R.GetSetTrackGroupMembership(tracks[1],'MEDIA_EDIT_LEAD',0,0)
assert(group~=0 and R.GetSetTrackGroupMembership(tracks[2],'MEDIA_EDIT_FOLLOW',0,0)&group~=0)
R.Main_OnCommand(40913,0)
R.Main_SaveProject(0,false)
local report=assert(io.open(root..'/Tests/scratch-setup.txt','w'))
report:write('Active: Scratch guitar + vocal\nScratch vocal: USB 9, armed, monitoring off\nScratch guitar: USB 15, armed, monitoring off\nAll other tracks disarmed. Both scratch tracks grouped with fixed lanes.\nFinal Vocals: USB 9. Final Electric guitar: USB 15.\nProject saved. Existing media retained: ',R.CountMediaItems(0),' items.\n')
report:close()
-- Only export a template while the song contains no recordings.
if R.CountMediaItems(0)==0 then
  local src=assert(io.open(path,'rb'));local data=src:read('*a');src:close()
  local out=assert(io.open(root..'/Templates/Solo Studio - Ethan X32.RPP','wb'));out:write(data);out:close()
end
local command=R.NamedCommandLookup('_RS64316da5bd79c2a658a42b415c6e5cdb22f9d602')
if command~=0 then R.Main_OnCommand(command,0) end
