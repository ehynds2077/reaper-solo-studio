-- Runs only in the visual checks' disposable project, with silent source media.
return function(M,check)
 local R=reaper;local ts=M.require_tracks();local P=M.preview()
 local function str(it,k)local _,v=R.GetSetMediaItemInfo_String(it,k,'',false);return v end
 local function named(name)for _,row in ipairs(M.lanes())do if row.name==name then return row end end end
 local full=named('Full song');local short=named('Short verse pass')
 M.use_in_comp(full.key,0,40)
 local source_key=short.key;local originals={};local guids={}
 for _,tr in ipairs(ts)do
  originals[tr]={}
  for i=0,R.CountTrackMediaItems(tr)-1 do
   local it=R.GetTrackMediaItem(tr,i);local ok,chunk=R.GetItemStateChunk(it,'',false);assert(ok)
   originals[tr][it]=chunk;guids[str(it,'GUID')]=true
  end
 end
 local function unchanged()
  for _,items in pairs(originals)do for it,chunk in pairs(items)do
   if not R.ValidatePtr(it,'MediaItem*')then return false end
   local ok,now=R.GetItemStateChunk(it,'',false)
   -- Native lane insertion changes only the fractional vertical geometry.
   local function audio(c)return c:gsub('\nYPOS %S+ %S+','\nYPOS')end
   if not ok or audio(now)~=audio(chunk)then return false end
  end end;return true
 end
 local function clean()
  local _,journal=R.GetProjExtState(0,M.ns,'comp.preview');if journal~=''then return false end
  for _,tr in ipairs(ts)do
   if R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')~=4 then return false end
   for i=0,R.CountTrackMediaItems(tr)-1 do if str(R.GetTrackMediaItem(tr,i),'P_EXT:SoloStudioPreview')~=''then return false end end
  end;return true
 end
 P.start(source_key,8,12,false)
 local correct=true;local identities={}
 for _,tr in ipairs(ts)do
  local items=M.lane_items(tr,4);correct=correct and #items==3 and R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:4')==1
  for _,it in ipairs(items)do
   local id=str(it,'GUID');correct=correct and not guids[id]and not identities[id];identities[id]=true
   local a=R.GetMediaItemInfo_Value(it,'D_POSITION');local b=a+R.GetMediaItemInfo_Value(it,'D_LENGTH')
   correct=correct and ((math.abs(a)<0.01 and math.abs(b-8)<0.01) or (math.abs(a-8)<0.01 and math.abs(b-12)<0.01) or (math.abs(a-12)<0.01 and math.abs(b-40)<0.01))
   if math.abs(a-8)<0.01 then local take=R.GetActiveTake(it);correct=correct and math.abs(R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS'))<0.01 end
  end
 end
 check(correct,'Preview replaces only the passage across all nine mics, with fresh item identities')
 check(unchanged(),'Preview leaves source recordings and saved comp item chunks untouched')
 P.cancel()
 check(clean() and unchanged(),'Cancel removes all temporary clips and restores the original lane counts')
 local playing=true;for _,tr in ipairs(ts)do playing=playing and R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..M.comp_lane(tr))==1 end
 check(playing,'Cancel restores saved comp playback on every microphone')
 -- Recovery uses the project journal, including after the creating module has gone away.
 P.start(source_key,8,12,false)
 dofile(debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')..'/Scripts/solo_comp_preview.lua')(M).cancel()
 check(clean()and unchanged(),'A fresh module recovers an interrupted preview without changing recordings')
 P.cancel()
 check(not pcall(P.start,source_key,8,16,false)and clean(),'Incomplete takes cannot replace a longer passage')
 -- Force failure on a later microphone to exercise transaction cleanup.
 local add=R.AddMediaItemToTrack;local copies=0
 R.AddMediaItemToTrack=function(tr)copies=copies+1;if copies==5 then return nil end;return add(tr)end
 local ok=pcall(P.start,source_key,8,12,false);R.AddMediaItemToTrack=add
 check(not ok and clean()and unchanged(),'Failed preview on a later microphone rolls back every temporary clip')
 R.GetSetRepeat(0);R.GetSet_LoopTimeRange2(0,true,false,0,0,false)
 R.SetMediaTrackInfo_Value(R.GetMasterTrack(0),'B_MUTE',1)
 R.SetEditCurPos2(0,1,false,false);R.OnPlayButton()
 P.start(source_key,8,12,true)
 check(R.GetPlayState()&1~=0 and R.GetCursorPosition()==1,'Preview preserves the running transport and edit cursor')
 P.start(full.key,8,12,true);check(R.GetPlayState()&1~=0,'Switching preview candidates keeps transport running')
 P.start(source_key,8,12,true)
 M.use_in_comp(source_key,8,12)
 local kept=true
 for _,tr in ipairs(ts)do
  local lane=M.comp_lane(tr);kept=kept and lane==0 and M.covers(M.lane_items(tr,lane),0,40)and R.GetMediaTrackInfo_Value(tr,'C_LANEPLAYS:'..lane)==1
  local found=false
  for _,it in ipairs(M.lane_items(tr,lane))do
   if str(it,'P_EXT:SoloStudioSource')==source_key then found=true end
  end;kept=kept and found
 end
 check(kept and clean() and R.GetPlayState()&1~=0,'Use in comp commits the selected source and preserves other passages without stopping playback')
 R.OnStopButton();R.Undo_DoUndo2(0)
 check(clean(),'Undoing the comp does not resurrect a temporary preview lane')
 -- Leave the final preview running for the deferred checks in the runner.
 P.start(source_key,8,12,true)
 return P
end
