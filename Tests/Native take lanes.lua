-- Runs inside the visual checks' disposable project, never the user's song.
return function(M,S,check,root)
 local R=reaper
 local ts=M.add_instrument('Drums',{'Kick','Snare top','Snare bottom','Tom 1','Tom 2','Hi-hat','OH L','OH R','Ride'})
 local set=M.get('active')
 for _,tr in ipairs(ts)do
  R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',3)
  for lane=0,2 do
   local ranges=lane==0 and {{0,40}}or lane==1 and {{8,14}}or {{8,16},{20,24}}
   for _,range in ipairs(ranges)do
    local it=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(it)
    R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
    R.SetMediaItemInfo_Value(it,'D_POSITION',range[1]);R.SetMediaItemInfo_Value(it,'D_LENGTH',range[2]-range[1]);R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',lane)
   end
   R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..lane,({'Full song','Short verse pass','Verse with a gap'})[lane+1],true)
  end
 end
 R.UpdateTimeline()
 check(#M.lanes()==3,'Native timeline discovers full, short, and split passes')
 M.favorite(1);M.note(1,'Good opening, stopped early')
 local key=M.row_for_lane(1).key
 local original=R.CountMediaItems(0)
 M.delete_take(1,key)
 check(R.CountMediaItems(0)==original-9 and #M.lanes()==2,'Deleting a short drum take removes all nine microphone items')
 local aligned=true;for _,tr in ipairs(ts)do aligned=aligned and R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')==3 and #M.lane_items(tr,0)==1 and #M.lane_items(tr,2)==2 end
 check(aligned,'Native deletion preserves adjacent takes and lane alignment')
 R.Undo_DoUndo2(0)
 local restored=M.row_for_lane(1)
 check(R.CountMediaItems(0)==original and restored and restored.key==key and restored.favorite and restored.note=='Good opening, stopped early','One native Undo restores all microphones, notes, favorite, and take identity')
 R.GetSet_LoopTimeRange2(0,true,false,8,12,false);M.comp(0)
 local source
 for _,row in ipairs(M.lanes())do if row.key==key then source=row end end
 check(source and source.lane==2,'Take identity follows native comp lane insertion')
 M.delete_take(source.lane,key)
 local comp_ok=true
 for _,tr in ipairs(ts)do comp_ok=comp_ok and #M.lane_items(tr,0)>0 and R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')==4 end
 check(comp_ok,'Deleting a source pass preserves every native comp and its lane index')
 R.Undo_DoUndo2(0)
 local undo_ok=true;for _,tr in ipairs(ts)do undo_ok=undo_ok and #M.lane_items(tr,2)==1 end
 check(undo_ok,'Undo restores a take after native comp insertion')
 -- Delete/restore the actual comp to exercise its item references as well.
 local comp=M.row_for_lane(0);M.delete_take(0,comp.key)
 local cleared=true;for _,tr in ipairs(ts)do local _,v=R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudioComp','',false);cleared=cleared and v==''end
 check(cleared,'Deleting the comp clears native comp references on every microphone')
 R.Undo_DoUndo2(0)
 R.GetSet_LoopTimeRange2(0,true,false,12,14,false)
 local full;for _,row in ipairs(M.lanes())do if row.name=='Full song'then full=row end end
 M.comp(full.lane)
 check(R.GetMediaTrackInfo_Value(ts[1],'I_NUMFIXEDLANES')==4,'Comping still reuses the restored native comp')
 M.choose_set(set)
 local section=S.list()[2];if section then S.select(section.key)end
end
