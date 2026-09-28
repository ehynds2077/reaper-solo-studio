-- Synthetic nine-microphone comps with real hidden source audio on both sides.
return function(M,check,root)
 local R=reaper;local names={};for i=1,9 do names[i]='Handle mic '..i end
 local ts=M.add_instrument('Comp handles',names);local a,b
 for _,tr in ipairs(ts)do
  local count=0;R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',3)
  for n=0,1 do
   local it=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(it)
   R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
   R.SetMediaItemInfo_Value(it,'D_POSITION',8+n*3);R.SetMediaItemInfo_Value(it,'D_LENGTH',3)
   R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',count+n);R.SetMediaItemTakeInfo_Value(take,'D_STARTOFFS',2)
   R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..(count+n),n==0 and 'Handle A'or 'Handle B',true)
   dofile(root..'/Scripts/solo_recording_handles.lua').tag_item(it,{first=6+n*3,last=15+n*3})
  end
  local it=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(it)
  R.SetMediaItemTake_Source(take,R.PCM_Source_CreateFromFile(root..'/Tests/silence.wav'))
  R.SetMediaItemInfo_Value(it,'D_POSITION',0);R.SetMediaItemInfo_Value(it,'D_LENGTH',8);R.SetMediaItemInfo_Value(it,'I_FIXEDLANE',2)
  R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:2','Early pass',true)
 end
 for _,row in ipairs(M.lanes())do if row.name=='Handle A'then a=row elseif row.name=='Handle B'then b=row end end
 M.use_in_comp(a.key,8,11);M.use_in_comp(b.key,11,14)
 local labelled=true
 for _,tr in ipairs(ts)do for _,it in ipairs(M.lane_items(tr,M.comp_lane(tr)))do
  local _,value=R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioRecordingBounds','',false);labelled=labelled and value~=''
 end end
 check(labelled,'Native comp copies retain the selected recording handles')
 local sources={};for _,tr in ipairs(ts)do for _,row in ipairs({M.row_for_key(a.key),M.row_for_key(b.key)})do
  for _,it in ipairs(M.lane_items(tr,row.lane))do local _,chunk=R.GetItemStateChunk(it,'',false);sources[it]=chunk end
 end end
 local B=M.comp_edges();local edge
 for _,candidate in ipairs(B.list())do if candidate.left and candidate.right and candidate.left.source==a.key and candidate.right.source==b.key then edge=candidate end end
 assert(edge,'Missing native comp join');local old=edge.pos;local plan=B.plan(edge.key)
 local regions=R.CountProjectMarkers(0);R.SetEditCurPos2(0,9,false,false);R.SetMediaTrackInfo_Value(R.GetMasterTrack(0),'B_MUTE',1);R.OnPlayButton()
 B.move(edge.key,12,plan.signature)
 local aligned=true
 for _,tr in ipairs(ts)do
  local left,right
  for _,it in ipairs(M.lane_items(tr,M.comp_lane(tr)))do local _,source=R.GetSetMediaItemInfo_String(it,'P_EXT:SoloStudioSource','',false)
   if source==a.key then left=it elseif source==b.key then right=it end
  end
  aligned=aligned and left and right and math.abs(R.GetMediaItemInfo_Value(left,'D_POSITION')+R.GetMediaItemInfo_Value(left,'D_LENGTH')-(12+edge.half))<0.00001
   and math.abs(R.GetMediaItemInfo_Value(right,'D_POSITION')-(12-edge.half))<0.00001
 end
 check(aligned,'Native comp join moves across all nine microphones into hidden media handles')
 check(R.GetPlayState()&1~=0 and R.GetCursorPosition()==9 and R.CountProjectMarkers(0)==regions,'Comp-edge editing preserves running transport and song regions')
 local untouched=true;for it,chunk in pairs(sources)do local _,now=R.GetItemStateChunk(it,'',false);untouched=untouched and now==chunk end
 check(untouched,'Comp-edge editing leaves original source takes untouched')
 R.OnStopButton();R.SetMediaTrackInfo_Value(R.GetMasterTrack(0),'B_MUTE',0);R.Undo_DoUndo2(0)
 local restored=B.plan(edge.key);check(math.abs(restored.pos-old)<0.00001,'One native Undo restores the original join on all microphones')
 B.move(edge.key,10);local moved=B.plan(edge.key).pos
 local full;for _,row in ipairs(M.lanes())do if row.name=='Early pass'then full=row end end
 M.use_in_comp(full.key,0,2)
 check(math.abs(B.plan(edge.key).pos-moved)<0.00001,'Comping elsewhere preserves a manually adjusted native join')
 check(not pcall(B.move,edge.key,17),'Native comp edges cannot extend beyond captured audio or consume adjacent passages')
 -- Leave the handle join selected in a useful range for visual inspection.
end
