-- Context-preserving signal taps and deferred, silent gain-reduction sampling.
local R=reaper;local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua');local State=dofile(dir..'/solo_mix_state.lua');local P={}
function P.signal(s,a,A)
 assert(a.track~='MASTER','Signal taps target ordinary tracks; measure_mix includes the master')
 local source=A.track(a.track,s.project);local mode=assert(({pre_fx=1,post_fx=3,post_fader=0})[a.point],'Choose pre_fx, post_fx or post_fader')
 local bounds=A.bounds(s,a);local tap,send;local selected={}
 for i=0,R.CountTracks(s.project)-1 do local tr=R.GetTrack(s.project,i);selected[#selected+1]={tr,R.IsTrackSelected(tr)}end
 local result;local ok,err=xpcall(function()
  R.InsertTrackAtIndex(R.CountTracks(s.project),false);tap=R.GetTrack(s.project,R.CountTracks(s.project)-1)
  R.GetSetMediaTrackInfo_String(tap,'P_NAME','Solo Studio analysis tap',true)
  R.SetMediaTrackInfo_Value(tap,'B_MAINSEND',0);R.SetMediaTrackInfo_Value(tap,'I_RECARM',0)
  R.SetMediaTrackInfo_Value(tap,'B_SHOWINTCP',0);R.SetMediaTrackInfo_Value(tap,'B_SHOWINMIXER',0)
  for i=R.GetTrackNumSends(tap,1)-1,0,-1 do R.RemoveTrackSend(tap,1,i)end
  send=R.CreateTrackSend(source,tap);assert(send>=0,'Could not create analysis tap')
  for key,value in pairs({D_VOL=1,D_PAN=0,B_MUTE=0,I_SENDMODE=mode,I_SRCCHAN=0,I_DSTCHAN=0,I_MIDIFLAGS=31})do R.SetTrackSendInfo_Value(source,0,send,key,value)end
  R.SetOnlyTrackSelected(tap)
  -- Bit 1 enables selected stems; bit 2 suppresses the accompanying master file.
  result=A.render(s,bounds,'signal:'..a.track..':'..a.point,3)
 end,debug.traceback)
 if send and send>=0 then R.RemoveTrackSend(source,0,send)end
 if tap and R.ValidatePtr2(s.project,tap,'MediaTrack*')then R.DeleteTrack(tap)end
 for _,row in ipairs(selected)do if R.ValidatePtr2(s.project,row[1],'MediaTrack*')then R.SetTrackSelected(row[1],row[2])end end
 A.remember(s);if not ok then error(err)end
 result.point=a.point;result.scope=a.point..' stereo track tap, before downstream buses/master. Full project processes in context; no solo or effect bypass.'
 return result
end
local function outputs(project)
 local rows={}
 for i=-1,R.CountTracks(project)-1 do
  local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i)
  for n=0,R.GetTrackNumSends(tr,1)-1 do rows[#rows+1]={track=i==-1 and 'MASTER'or R.GetTrackGUID(tr),index=n,volume=R.GetTrackSendInfo_Value(tr,1,n,'D_VOL'),destination=R.GetTrackSendInfo_Value(tr,1,n,'I_DSTCHAN'),source=R.GetTrackSendInfo_Value(tr,1,n,'I_SRCCHAN')}end
 end
 return rows
end
function P.cleanup(s,A)
 local job=s.probe;if not job then return end
 if R.ValidatePtr(s.project,'ReaProject*')then
  local recording=R.GetPlayStateEx(s.project)&4~=0
  if not recording then R.OnStopButtonEx(s.project)end
  for _,row in ipairs(job.outputs)do
   local ok,tr=pcall(A.track,row.track,s.project)
   if ok and row.index<R.GetTrackNumSends(tr,1)
    and (row.destination==nil or row.destination==R.GetTrackSendInfo_Value(tr,1,row.index,'I_DSTCHAN'))
    and (row.source==nil or row.source==R.GetTrackSendInfo_Value(tr,1,row.index,'I_SRCCHAN'))
    and R.GetTrackSendInfo_Value(tr,1,row.index,'D_VOL')==0 then
    R.SetTrackSendInfo_Value(tr,1,row.index,'D_VOL',row.volume)
    assert(math.abs(R.GetTrackSendInfo_Value(tr,1,row.index,'D_VOL')-row.volume)<1e-8,'Could not restore hardware volume; probe-restore.json retained for recovery')
   end
  end
  if not recording then
   R.GetSetRepeatEx(s.project,job.repeat_mode)
   R.SetEditCurPos2(s.project,job.cursor,false,false)
  end
 end
 s.probe=nil;os.remove(s.path..'/probe-restore.json')
end
function P.recover(s,A)
 local saved=J.read(s.path..'/probe-restore.json');if not saved then return end
 assert(R.GetPlayState()&4==0,'Finish recording before restoring interrupted measurement outputs')
 s.probe=saved;P.cleanup(s,A)
end
function P.start(s,a,A)
 assert(not s.probe,'A gain-reduction probe is already active')
 assert(R.GetAllProjectPlayStates()==0,'Stop transport in every project before a gain-reduction probe')
 assert(type(a.effects)=='table'and #a.effects>0 and #a.effects<=16,'Choose 1–16 effects')
 local bounds=A.bounds(s,a);assert(bounds[2]-bounds[1]<=30,'Use a representative 3–30 second passage for gain reduction')
 local job={bounds=bounds,cursor=R.GetCursorPositionEx(s.project),repeat_mode=R.GetSetRepeatEx(s.project,-1),outputs=outputs(s.project),effects=J.array(),started=R.time_precise(),last_sample=-1}
 local supported=0
 for _,spec in ipairs(a.effects)do
  local tr=A.track(spec.track,s.project);local idx=A.fx_index(tr,spec.effect)
  local _,name=R.TrackFX_GetFXName(tr,idx,'');local ok,value=R.TrackFX_GetNamedConfigParm(tr,idx,'GainReduction_dB')
  local valid=ok and tonumber(value)~=nil and R.TrackFX_GetEnabled(tr,idx)and not R.TrackFX_GetOffline(tr,idx)
  job.effects[#job.effects+1]={track=spec.track,effect=spec.effect,plugin=name,supported=not not valid,samples=J.array(),max_db=0,sum_db=0}
  if valid then supported=supported+1 end
 end
 if supported==0 then return {effects=job.effects,note='None of these active plugins exposes GainReduction_dB. No playback was started; do not infer gain reduction from crest.'}end
 J.write(s.path..'/probe-restore.json',job);s.probe=job
 local ok,err=pcall(function()
  for _,row in ipairs(job.outputs)do R.SetTrackSendInfo_Value(A.track(row.track,s.project),1,row.index,'D_VOL',0)end
  R.GetSetRepeatEx(s.project,0);R.SetEditCurPos2(s.project,bounds[1],false,false)
  R.OnPlayButtonEx(s.project);job.version=R.GetProjectStateChangeCount(s.project);job.signature=State.capture(s.project)
 end)
 if not ok then P.cleanup(s,A);A.remember(s);error(err)end
 return {pending=true}
end
function P.poll(s,A,cancel)
 local job=s.probe;if not job then return end
 local now=R.time_precise();local pos=R.GetPlayPositionEx(s.project);local failure
 local version=R.GetProjectStateChangeCount(s.project)
 if version==job.version+1 and State.window_action(R.Undo_CanUndo2(s.project))and State.capture(s.project)==job.signature then job.version=version end
 if R.EnumProjects(-1,'')~=s.project then failure='Project switched during gain-reduction measurement'
 elseif R.GetProjectStateChangeCount(s.project)~=job.version then failure='Project edited during gain-reduction measurement'
 elseif cancel then failure='Gain-reduction measurement cancelled'
 elseif now-job.started>job.bounds[2]-job.bounds[1]+10 then failure='Audio engine did not advance through the measurement'
 elseif R.GetPlayStateEx(s.project)&4~=0 then failure='Recording started during gain-reduction measurement'
 elseif R.GetPlayStateEx(s.project)&1==0 and pos<job.bounds[2]then failure='Playback stopped during gain-reduction measurement'end
 if not failure and pos>=job.bounds[1]and pos<=job.bounds[2]and now-job.last_sample>=.05 then
  job.last_sample=now
  for _,row in ipairs(job.effects)do if row.supported then
   local tr=A.track(row.track,s.project);local index=A.fx_index(tr,row.effect)
   local ok,value=R.TrackFX_GetNamedConfigParm(tr,index,'GainReduction_dB');local v=ok and tonumber(value)
   if v and v==v and math.abs(v)<150 then
    local reduction=math.abs(v);row.max_db=math.max(row.max_db,reduction);row.sum_db=row.sum_db+reduction
    row.samples[#row.samples+1]={seconds=pos,reduction_db=reduction}
   end
  end end
 end
 if failure or pos>=job.bounds[2]then
  P.cleanup(s,A)
  if failure and failure:find('edited')then s.recovery_changed=true end
  A.remember(s)
  if failure then return {error=failure}end
  for _,row in ipairs(job.effects)do
   row.sample_count=#row.samples
   if row.sample_count>0 then
    row.mean_db=row.sum_db/row.sample_count;local values={};for _,v in ipairs(row.samples)do values[#values+1]=v.reduction_db end;table.sort(values);row.p95_db=values[math.max(1,math.ceil(#values*.95))]
   else row.max_db=nil end
   row.sum_db=nil
  end
  return {result={bounds=job.bounds,effects=job.effects,note='Sampled plugin-reported gain reduction at up to 20 Hz during silent real-time playback. Brief inter-sample peaks can be missed; unsupported plugins have no inferred readings.'}}
 end
end
return P
