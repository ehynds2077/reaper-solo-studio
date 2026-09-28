-- Native Undo/Redo and a disposable panel fixture; closing it restores the user's song.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local M=dofile(root..'/Scripts/solo_core.lua');local S=M.sections()
assert(R.GetPlayState()==0,'Stop transport before opening the boundary history checks.')
local original=R.EnumProjects(-1,'')
local snapshot={items=R.CountMediaItems(0),tracks=R.CountTracks(0),markers=R.CountProjectMarkers(0),tempo=R.Master_GetTempo(),chunks={}}
for i=0,R.CountTracks(0)-1 do local tr=R.GetTrack(0,i);local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok);snapshot.chunks[R.GetTrackGUID(tr)]=chunk end
local filename=root..'/Tests/Boundary history checks.RPP'
local f=assert(io.open(filename,'w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
R.Main_OnCommand(41929,0);R.Main_openProject(filename)
local project=R.EnumProjects(-1,'')
local log=assert(io.open(root..'/Tests/boundary-history-checks.txt','w'));local count=0
local function check(ok,label)assert(ok,label);count=count+1;log:write('PASS: '..label..'\n');log:flush()end
local function cleanup()
 if R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project);R.OnStopButton();R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 check(R.CountMediaItems(0)==snapshot.items and R.CountTracks(0)==snapshot.tracks and R.CountProjectMarkers(0)==snapshot.markers and R.Master_GetTempo()==snapshot.tempo,'User song media, tracks, regions, and tempo preserved')
 local same=true
 for i=0,R.CountTracks(0)-1 do local tr=R.GetTrack(0,i);local ok,chunk=R.GetTrackStateChunk(tr,'',false);same=same and ok and snapshot.chunks[R.GetTrackGUID(tr)]==chunk end
 check(same,'Original song track contents, comp edits, effects, and settings preserved exactly')
 log:write(count..' native boundary-history checks passed.\n');log:close()
end
local ok,err=xpcall(function()
 local ts=M.add_instrument('Drums',{'Kick','Snare top','Snare bottom','Tom 1','Tom 2','Hi-hat','OH L','OH R','Ride'})
 for _,tr in ipairs(ts)do
  R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',2)
  for lane=0,1 do
   local it=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(it)
   local source=R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav');assert(source,'Generate Tests/silence.wav with Tests/make_fixtures.py first.')
   R.SetMediaItemTake_Source(take,source)
   R.SetMediaItemInfo_Value(it,'D_POSITION',8+lane*4);R.SetMediaItemInfo_Value(it,'D_LENGTH',4)
   R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',lane);R.SetMediaItemTakeInfo_Value(take,'D_STARTOFFS',4)
   R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..lane,'Take '..(lane+1),true)
  end
 end
 local takes=M.lanes();M.use_in_comp(takes[1].key,8,12);M.use_in_comp(takes[2].key,12,16)
 S.create(0,8,'Intro');S.create(8,12,'Verse');local chorus=S.create(12,16,'Chorus');S.select(chorus.key)
 local B=M.comp_edges();local edge
 for _,candidate in ipairs(B.list())do if candidate.kind=='roll'then edge=candidate;break end end
 assert(edge,'Missing comp join')
 local position=edge.pos;R.SetMediaTrackInfo_Value(R.GetMasterTrack(0),'B_MUTE',1)
 R.OnPlayButton();B.move(edge.key,position+0.25)
 check(R.Undo_CanUndo2(0)=='Solo Studio: move comp boundary','A boundary drag creates one clearly named native Undo entry')
 M.history(false)
 check(math.abs(B.plan(edge.key).pos-position)<0.00001,'Undo restores the boundary and source offsets across nine microphones')
 check(R.GetPlayState()&1~=0 and R.GetCursorPosition()==12,'Undo keeps playback running and the edit cursor in place')
 check(R.Undo_CanRedo2(0)=='Solo Studio: move comp boundary','Undo leaves the matching Redo entry available')
 M.history(true)
 check(math.abs(B.plan(edge.key).pos-position-0.25)<0.00001 and R.GetPlayState()&1~=0,'Redo reapplies the nine-microphone boundary without stopping playback')
 M.history(false);R.OnStopButton();R.SetMediaTrackInfo_Value(R.GetMasterTrack(0),'B_MUTE',0)
 local T=dofile(root..'/Scripts/solo_tracks.lua')(M)
 local first=R.GetTrackGUID(M.tracks()[1]);T.rename(first,'Kick close')
 check(M.track_name(M.tracks()[1])=='Kick close','Native Tracks rename updates the track')
 M.history(false);check(M.track_name(M.tracks()[1])=='Kick','Panel Undo also restores track names')
 local last=R.GetTrackGUID(M.tracks()[9]);T.delete(T.plan_delete(last))
 check(#M.tracks()==8,'Deleting a microphone retains the remaining recording set')
 M.history(false)
 check(#M.tracks()==9 and R.GetTrackGUID(M.tracks()[9])==last,'Native Undo restores the deleted microphone, its recordings, and set membership')
 -- Leave one boundary edit ready for the visible Undo button and keyboard checks.
 B.move(edge.key,position+0.25)
 R.SetExtState(M.ns,'panel_view','timeline',false);R.Main_SaveProjectEx(project,filename,8)
 dofile(root..'/Scripts/Solo Studio - Open recording panel.lua')
 R.atexit(cleanup)
end,debug.traceback)
if not ok then log:write('FAIL: '..err..'\n');log:flush();cleanup();R.ShowMessageBox(err,'Boundary history checks failed',0)end
