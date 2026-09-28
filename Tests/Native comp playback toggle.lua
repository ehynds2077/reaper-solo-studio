-- Direct Comp / Take switching in the disposable nine-microphone fixture.
return function(M,check)
 local R=reaper;local ts=M.require_tracks();local originals={};local stable={};local lanes={};local volumes={}
 local function item_audio(it)
  local values={};for _,key in ipairs({'D_POSITION','D_LENGTH','D_VOL','D_FADEINLEN','D_FADEOUTLEN','I_FIXEDLANE'})do values[#values+1]=R.GetMediaItemInfo_Value(it,key)end
  for _,key in ipairs({'GUID','P_EXT:SoloStudioRecordedTempo','P_EXT:SoloStudioSource','P_EXT:SoloStudioSourceName'})do local _,v=R.GetSetMediaItemInfo_String(it,key,'',false);values[#values+1]=v end
  local take=R.GetActiveTake(it)
  if take then
   for _,key in ipairs({'D_STARTOFFS','D_PLAYRATE','D_PITCH','D_VOL','D_PAN'})do values[#values+1]=R.GetMediaItemTakeInfo_Value(take,key)end
   values[#values+1]=R.GetMediaSourceFileName(R.GetMediaItemTake_Source(take),'')
  end
  return table.concat(values,'|')
 end
 local full,short,gapped
 for _,row in ipairs(M.lanes())do
  if row.name=='Full song'then full=row elseif row.name=='Short verse pass'then short=row elseif not row.is_comp and #row.items>1 then gapped=row end
 end
 assert(full and short and gapped,'Missing toggle fixtures')
 for _,tr in ipairs(ts)do
  lanes[tr]=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES');volumes[tr]=R.GetMediaTrackInfo_Value(tr,'D_VOL')
  for i=0,R.CountTrackMediaItems(tr)-1 do local it=R.GetTrackMediaItem(tr,i);local ok,chunk=R.GetItemStateChunk(it,'',false);assert(ok);local _,id=R.GetSetMediaItemInfo_String(it,'GUID','',false);originals[id]=chunk;stable[id]=item_audio(it) end
 end
 local function active(lane)
  for _,tr in ipairs(ts)do for n=0,lanes[tr]-1 do
   if R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..n)~=(n==lane and 1 or 0)then return false end
  end end;return true
 end
 local function unchanged(after_undo)
  local by_id={};for _,tr in ipairs(ts)do for i=0,R.CountTrackMediaItems(tr)-1 do
   local it=R.GetTrackMediaItem(tr,i);local _,id=R.GetSetMediaItemInfo_String(it,'GUID','',false);by_id[id]=it
  end end
  local count=0;for id,chunk in pairs(originals)do
   local it=by_id[id];if not it then return false end
   local ok,now=R.GetItemStateChunk(it,'',false)
   -- REAPER recalculates automatic crossfades on Undo; manual fades and audio must survive.
   if not ok or (after_undo and item_audio(it)~=stable[id])or (not after_undo and now~=chunk)then return false end;count=count+1
  end
  local current=0;for _,tr in ipairs(ts)do
   current=current+R.CountTrackMediaItems(tr)
   if R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')~=lanes[tr]or R.GetMediaTrackInfo_Value(tr,'D_VOL')~=volumes[tr]then return false end
  end
  return current==count and M.get('comp.preview')==''
 end
 R.GetSetRepeat(0);R.GetSet_LoopTimeRange2(0,true,false,0,40,false);R.SetEditCurPos2(0,1,false,false)
 M.audition(short.lane,true)
 check(active(short.lane)and R.GetPlayState()==0,'Take toggle selects a partial whole lane on all nine mics without starting transport')
 M.audition(gapped.lane,true)
 check(active(gapped.lane),'Take toggle accepts a split source lane without requiring coverage of the song selection')
 M.listen_comp()
 check(active(M.comp_lane(ts[1]))and R.GetPlayState()==0,'Comp toggle restores saved playback while stopped')
 local master=R.GetMasterTrack(0);local muted=R.GetMediaTrackInfo_Value(master,'B_MUTE');R.SetMediaTrackInfo_Value(master,'B_MUTE',1)
 R.OnPlayButton()
 local success,err=xpcall(function()
  for _,row in ipairs({short,full,gapped,short})do
   M.audition(row.lane,true)
   assert(active(row.lane)and R.GetPlayState()&1~=0,'Take interrupted playback')
   M.listen_comp();assert(active(M.comp_lane(ts[1]))and R.GetPlayState()&1~=0,'Comp interrupted playback')
  end
  local a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  check(a==0 and b==40 and R.GetCursorPosition()==1,'Repeated Comp / Take switches preserve transport, cursor, and time selection')
  check(unchanged(),'Switching creates no temporary clips and preserves source/comp chunks, tempo labels, and faders')
  M.audition(short.lane,true);R.OnStopButton()
  check(active(short.lane),'Stopping playback keeps the chosen Take lane active')
  M.delete_takes({M.row_for_key(short.key)},full.key)
  check(active(full.lane)and not M.row_for_key(short.key),'Deleting the selected take switches every microphone to its surviving neighbor')
  R.Undo_DoUndo2(0)
  check(M.row_for_key(short.key)and active(short.lane),'One native Undo restores deleted audio and its prior playback lane')
  check(unchanged(true),'Undo preserves source/comp identities, audio, manual fades, and tempo labels')
 end,debug.traceback)
 R.OnStopButton();R.SetMediaTrackInfo_Value(master,'B_MUTE',muted)
 assert(success,err);M.listen_comp()
end
