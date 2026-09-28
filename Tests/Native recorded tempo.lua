-- Native items in the visual fixture; no live inputs are recorded.
return function(M,check,root)
 local R=reaper;local Q=M.recorded_tempo();local tracks=M.require_tracks();local project=R.EnumProjects(-1,'')
 local before={};for _,row in ipairs(M.lanes())do before[row.key]=true end
 local old_bpm=R.Master_GetTempo()
 R.SetCurrentBPM(0,110,true);Q.begin(project,tracks)
 for _,tr in ipairs(tracks)do
  local lane=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES');R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',lane+1)
  local it=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(it)
  R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
  R.SetMediaItemInfo_Value(it,'D_POSITION',8);R.SetMediaItemInfo_Value(it,'D_LENGTH',6);R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',lane)
  R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..lane,'110 BPM pass',true)
 end
 R.SetCurrentBPM(0,old_bpm,true);Q.finish(project)
 local fresh;for _,row in ipairs(M.lanes())do if not before[row.key]then fresh=row end end
 check(fresh and fresh.tempo.bpm==110 and fresh.tempo.different,'Native take displays its captured BPM after the song tempo changes')
 local ok=true;for _,tr in ipairs(tracks)do ok=ok and Q.read(M.lane_items(tr,fresh.lane)[1]).bpm==110 end
 check(ok,'Recorded BPM is attached to all nine microphone clips')
 Q.assign({fresh},115)
 check(M.row_for_key(fresh.key).tempo.bpm==115,'Manual BPM label updates the whole selected take')
 R.Undo_DoUndo2(0)
 local restored=M.row_for_key(fresh.key)
 check(restored and restored.tempo.bpm==110,'One native Undo restores the previous tempo labels (actual: '..(restored and restored.tempo.label or 'missing take')..'; redo: '..tostring(R.Undo_CanRedo2(0))..')')
 M.use_in_comp(fresh.key,8,12)
 ok=true;for _,tr in ipairs(tracks)do
  local found=false;for _,it in ipairs(M.lane_items(tr,M.comp_lane(tr)))do local d=Q.read(it);if d and d.bpm==110 then found=true end end;ok=ok and found
 end
 check(ok,'Comp copies retain their source recording tempo across all microphones')
 local it=M.lane_items(tracks[1],M.row_for_key(fresh.key).lane)[1]
 local right=R.SplitMediaItem(it,10)
 check(right and Q.read(right).bpm==110 and Q.read(it).bpm==110,'Splitting a clip preserves its recorded tempo on both pieces')
 local savefile=root..'/Tests/Visual tempo persistence.RPP'
 R.Main_SaveProjectEx(project,savefile,8)
 local file=assert(io.open(savefile,'r'));local contents=file:read('*a');file:close()
 check(contents:find('SoloStudioRecordedTempo',1,true)~=nil,'Recorded tempo metadata is written to the native project file')
 -- Leave three contrasting labels in the fixture for visual review.
 local row;for _,candidate in ipairs(M.lanes())do if candidate.name=='Full song'then row=candidate end end
 Q.assign({row},old_bpm)
end
