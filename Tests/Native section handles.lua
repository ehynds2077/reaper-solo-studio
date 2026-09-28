-- Records silent OUTPUT in the disposable project, never hardware inputs.
return function(M,S,check,root,done)
 local R=reaper;local H=dofile(root..'/Scripts/solo_recording_handles.lua');local initial_pre=R.GetToggleCommandStateEx(0,41819);local initial_link=R.GetToggleCommandStateEx(0,40621)
 local original_set=M.get('active');local arm=M.arm
 local tracks=M.add_instrument('Handle capture test',{'Handle output L','Handle output R'})
 for _,tr in ipairs(tracks)do R.SetMediaTrackInfo_Value(tr,'B_MAINSEND',0)end
 M.arm=function()
  R.ClearAllRecArmed()
  for _,tr in ipairs(tracks)do
   R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',-1);R.SetMediaTrackInfo_Value(tr,'I_RECMODE',1)
   R.SetMediaTrackInfo_Value(tr,'I_RECMON',0);R.SetMediaTrackInfo_Value(tr,'I_RECARM',1)
  end
 end
 local row=S.list()[1];local region=R.AddProjectMarker2(0,true,48,49,'Handle recording test',-1,0)
 for _,r in ipairs(S.list())do if r.id==region then row=r end end
 S.select(row.key);S.set_loop(false)
 local project=R.EnumProjects(-1,'');local master=R.GetMasterTrack(project);local mute=R.GetMediaTrackInfo_Value(master,'B_MUTE')
 R.SetMediaTrackInfo_Value(master,'B_MUTE',1)
 local started=R.time_precise();local phase='one';local loops=0;local previous;local first_count
 local function end_test(err)
  M.stop();M.arm=arm;S.set_loop(false);R.SetMediaTrackInfo_Value(master,'B_MUTE',mute);M.choose_set(original_set)
  local verse=S.list()[2];if verse then S.select(verse.key)end
  done(err)
 end
 local function handle(it)
  local take=R.GetActiveTake(it);local src=R.GetMediaItemTake_Source(take)
  local length=R.GetMediaSourceLength(src);local offset=R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS');local duration=R.GetMediaItemInfo_Value(it,'D_LENGTH')
  return offset,length-offset-duration
 end
 local function verify(count)
  for _,tr in ipairs(tracks)do
   local complete=0
   for i=0,R.CountTrackMediaItems(tr)-1 do
    local it=R.GetTrackMediaItem(tr,i);local s=R.GetMediaItemInfo_Value(it,'D_POSITION');local length=R.GetMediaItemInfo_Value(it,'D_LENGTH')
    if math.abs(s-48)<0.02 and math.abs(length-1)<0.02 then
     local before,after=handle(it)
     local f=assert(io.open(root..'/Tests/section-handle-media.txt','a'));f:write(string.format('%s start=%.6f length=%.6f before=%.6f after=%.6f\n',phase,s,length,before,after));f:close()
     assert(before>=3.95 and after>=3.95,'Missing two-bar media handles: before='..before..', after='..after)
     local take=R.GetActiveTake(it);local first,last=H.bounds(it,R.GetMediaItemTake_Source(take))
     local offset=R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')
     assert(first and math.abs(offset-first-4)<0.02 and math.abs(last-offset-length-4)<0.02,'Stored handle bounds must exclude other loop passes')
     complete=complete+1
    end
   end
   assert(complete>=count,'Missing complete trimmed section passes')
  end
 end
 local ok,err=pcall(M.record);if not ok then end_test(err);return end
 local function poll()
  local ok,err=xpcall(function()
   assert(R.ValidatePtr(project,'ReaProject*'),'Handle test project closed')
   local state=R.GetPlayStateEx(project);local pos=R.GetPlayPositionEx(project)
   assert(R.time_precise()-started<40,'Section handle recording timed out')
   if phase=='one'then
    if state&4~=0 then R.defer(poll);return end
    M.finish_recorded_tempo();if M.recorded_tempo().job(project)then R.defer(poll);return end;verify(1);check(true,'One-pass recording captures two bars before and after while native clips stay trimmed to the section')
    first_count=R.CountTrackMediaItems(tracks[1]);S.set_loop(true);M.record()
    local ls,le=R.GetSet_LoopTimeRange2(0,false,true,0,0,false);local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
    check(math.abs(ls-44)<0.00001 and math.abs(le-53)<0.00001 and s==48 and e==49,'Loop bounds include both handles while punch bounds remain exactly the section ('..ls..','..le..' / '..s..','..e..')')
    phase='loop';previous=nil
   elseif phase=='loop'then
    assert(state&4~=0,'Looped handle recording stopped unexpectedly')
    if previous and previous>52 and pos<45 then loops=loops+1 end;previous=pos
    if loops>=2 then M.stop();phase='loop_finish'end
   else
    M.finish_recorded_tempo();if M.recorded_tempo().job(project)then R.defer(poll);return end
    verify(3)
    check(R.CountTrackMediaItems(tracks[1])>=first_count+2,'Repeated loop passes each retain two-bar handles limited to their own performance')
    check(R.GetToggleCommandStateEx(0,41819)==initial_pre and R.GetToggleCommandStateEx(0,40621)==initial_link and not H.job(project),'Stop restores pre-roll and loop-link preferences and clears capture settings')
    end_test();return
   end
   R.defer(poll)
  end,debug.traceback)
  if not ok then end_test(err)end
 end
 R.defer(poll)
end
