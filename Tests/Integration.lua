local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local M=dofile(root..'/Scripts/solo_core.lua')
local original=reaper.EnumProjects(-1,'')
local output=assert(io.open(root..'/Tests/integration-results.txt','w'))
local function log(s) output:write(s..'\n'); output:flush() end
local function check(v,s) assert(v,s); log('PASS '..s) end
reaper.Main_OnCommand(41929,0)
local testproj=reaper.EnumProjects(-1,'')
local ok,err=xpcall(function()
 local tracks=M.add_instrument('Drums',{'Test kick','Test snare'})
 for _,tr in ipairs(tracks) do
  reaper.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',2)
  for lane=0,1 do
   local item=reaper.AddMediaItemToTrack(tr)
   local take=reaper.AddTakeToMediaItem(item)
   reaper.SetMediaItemTake_Source(take,reaper.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
   reaper.SetMediaItemInfo_Value(item,'D_POSITION',0)
   reaper.SetMediaItemInfo_Value(item,'D_LENGTH',8)
   reaper.SetMediaItemInfo_Value(item,'I_FIXEDLANE',lane)
   reaper.GetSetMediaItemTakeInfo_String(take,'P_NAME','Take '..(lane+1),true)
  end
 end
 reaper.UpdateTimeline()
 check(#M.lanes()==2,'Two takes discovered')
 M.audition(0)
 for _,tr in ipairs(tracks) do check(reaper.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:0')==1,'First take plays exclusively') end
 M.step(1)
 for _,tr in ipairs(tracks) do check(reaper.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:1')==1,'Next take switches both microphones') end
 M.favorite(1); M.note(1,'Keep the ending')
 check(M.row_for_lane(1).favorite,'Favorite stored')
 check(M.row_for_lane(1).note=='Keep the ending','Note stored')
 M.note(1,'Nice fill',{2,4});check(M.section_note(1,2,4)=='Nice fill','Section note stored separately')
 reaper.GetSet_LoopTimeRange2(0,true,false,2,4,false)
 M.comp(1)
 for i,tr in ipairs(tracks) do
  local _,chunk=reaper.GetTrackStateChunk(tr,'',false)
  local f=assert(io.open(root..'/Tests/comp-track-'..i..'.txt','w'));f:write(chunk);f:close()
  check(reaper.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')==3,'Native comp lane created')
  check(reaper.CountTrackMediaItems(tr)>2,'Comp contains copied audio')
  local found=false
  for j=0,reaper.CountTrackMediaItems(tr)-1 do
   local it=reaper.GetTrackMediaItem(tr,j)
   if math.abs(reaper.GetMediaItemInfo_Value(it,'D_POSITION')-2)<0.001 and math.abs(reaper.GetMediaItemInfo_Value(it,'D_LENGTH')-2)<0.02 then found=true end
  end
  check(found,'Comp preserves requested passage bounds')
 end
 local rows=M.lanes(); local source
 for _,row in ipairs(rows) do if row.note=='Keep the ending' then source=row end end
 check(source~=nil,'Take note follows source after lane insertion')
 reaper.Undo_DoUndo2(0)
 check(reaper.GetMediaTrackInfo_Value(tracks[1],'I_NUMFIXEDLANES')==2,'Undo removes the complete multitrack comp operation')
 local _,compmeta=reaper.GetSetMediaTrackInfo_String(tracks[1],'P_EXT:SoloStudioComp','',false)
 check(compmeta=='','Undo restores comp metadata')
 reaper.GetSet_LoopTimeRange2(0,true,false,2,4,false)
 M.comp(1)
 for _,row in ipairs(M.lanes()) do if row.note=='Keep the ending' then source=row end end
 reaper.GetSet_LoopTimeRange2(0,true,false,5,6,false)
 M.audition(source.lane)
 M.comp(source.lane)
 for _,tr in ipairs(tracks) do check(reaper.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')==3,'Second commit reuses comp lane') end
 reaper.SetMediaTrackInfo_Value(tracks[2],'I_NUMFIXEDLANES',4)
 local counts={reaper.GetMediaTrackInfo_Value(tracks[1],'C_LANEPLAYS:0'),reaper.GetMediaTrackInfo_Value(tracks[2],'C_LANEPLAYS:0')}
 local rejected=not pcall(M.audition,source.lane)
 check(rejected,'Mismatched microphone lanes are rejected before switching')
 check(reaper.GetMediaTrackInfo_Value(tracks[1],'C_LANEPLAYS:0')==counts[1],'Failed switch preserves playback')
 reaper.SetMediaTrackInfo_Value(tracks[2],'I_NUMFIXEDLANES',3)
 reaper.GetSet_LoopTimeRange2(0,true,false,7,9,false)
 check(not pcall(M.audition,source.lane),'Incomplete take coverage is rejected')
 reaper.Main_SaveProjectEx(testproj,root..'/Tests/Integration fixture.rpp',8)
 reaper.Main_OnCommand(40860,0)
 reaper.Main_OnCommand(41929,0)
 reaper.Main_openProject(root..'/Tests/Integration fixture.rpp')
 testproj=reaper.EnumProjects(-1,'')
 check(#M.tracks()==2,'Recording set survives save and reopen')
 local persisted=false
 for _,row in ipairs(M.lanes()) do if row.note=='Keep the ending' and row.favorite and M.section_note(row.lane,2,4)=='Nice fill' then persisted=true end end
 check(persisted,'Take notes, favorites and passage notes survive save and reopen')
 log('ALL INTEGRATION CHECKS PASSED')
end,debug.traceback)
if not ok then log('FAIL '..err) end
reaper.Main_SaveProjectEx(testproj,root..'/Tests/Integration fixture.rpp',8)
reaper.Main_OnCommand(40860,0)
reaper.SelectProjectInstance(original)
output:close()
if not ok then reaper.ShowMessageBox(err,'Solo Studio test failure',0) end
