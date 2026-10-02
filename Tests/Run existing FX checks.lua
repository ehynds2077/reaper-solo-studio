-- Existing ReaEQ plus a copy of the real project's Pro-L 2; no model requests.
-- A separate project has no hardware outputs. Restore the original tab unchanged.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local F=dofile(root..'/Scripts/solo_mix_effects.lua')
local State=dofile(root..'/Scripts/solo_mix_state.lua');local J=B.json
local log=assert(io.open(root..'/Tests/existing-fx-native-checks.txt','w'))
local original=R.EnumProjects(-1,'');local before=State.capture(original)
local project,job,s;local passed=0
local native_set_chunk=R.SetTrackStateChunk
local function check(ok,name)assert(ok,name);passed=passed+1;log:write('PASS '..name..'\n');log:flush()end
local ok,err=xpcall(function()
 assert(R.GetAllProjectPlayStates()==0,'Stop all transport before testing')
 assert(R.GetExtState('SoloStudio_v1','panel_open')~='1','Close Solo Studio before testing')
 local source=R.GetMasterTrack(original);local source_idx
 for i=0,R.TrackFX_GetCount(source)-1 do local _,name=R.TrackFX_GetFXName(source,i,'');if name:find('Pro%-L 2')then source_idx=i end end
 assert(source_idx,'Current project needs an existing Pro-L 2 to copy')
 job=root..'/Tests/Existing FX data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/Existing FX.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/Existing FX.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project)
 R.TrackFX_CopyToTrack(source,source_idx,master,0,false)
 R.TrackFX_SetOffline(master,0,true)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Test project has no hardware outputs')
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(project,0);local id=R.GetTrackGUID(tr)
 R.GetSetMediaTrackInfo_String(tr,'P_NAME','Existing EQ test',true);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0)
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav')))
 R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 local eq=R.TrackFX_AddByName(tr,'VST: ReaEQ (Cockos)',false,-1);assert(eq>=0)
 local eqid=R.TrackFX_GetFXGUID(tr,eq);local limiter=R.TrackFX_GetFXGUID(master,0)
 local original_eq=F.capture(tr,eqid);local original_limiter=F.capture(master,limiter)
 s=B.begin(job,{0,8});local info=B.inspect(s)
 check(info.master.effects[1].id==limiter and info.master.effects[1].offline and info.tracks[1].effects[1].id==eqid,'Inspection exposes existing GUIDs and offline state')
 local offline=B.execute(s,'inspect_effect',{track='MASTER',effect=limiter})
 check(offline.offline and #s.owned==0 and not s.modified,'Read-only inspection never creates ownership or changes offline state')
 B.execute(s,'set_effect_state',{track='MASTER',effect=limiter,offline=false,enabled=true})
 B.execute(s,'configure_limiter',{track='MASTER',effect=limiter,gain_db=12,ceiling_db=-2})
 B.execute(s,'configure_eq',{track=id,effect=eqid,band='bell',band_index=0,frequency_hz=800,gain_db=4})
 check(#s.modified==2 and #s.owned==0,'Existing plugins are snapshotted once, not treated as added effects')
 local candidate_eq=F.capture(tr,eqid);local candidate_limiter=F.capture(master,limiter)
 check(not F.same(original_eq,candidate_eq)and not F.same(original_limiter,candidate_limiter),'Candidate changes existing EQ and real-project limiter copy')
 local render=B.execute(s,'measure_mix',{});J.write(job..'/render-result.json',render)
 R.SetTrackStateChunk=function(t,chunk,undo)
  local result=native_set_chunk(t,chunk,undo)
  local _,after=R.GetTrackStateChunk(t,'',false)
  if chunk~=after then
   local f=assert(io.open(job..'/plugin-restores.jsonl','a'));f:write(J.encode({wanted=chunk,actual=after}),'\n');f:close()
  end
  return result
 end
 R.OnPlayButtonEx(project)
 B.compare(s,'original')
 check(R.GetPlayState()&1~=0 and F.same(F.capture(tr,eqid),original_eq)and F.same(F.capture(master,limiter),original_limiter),'Live Original restores complete existing plugin states without stopping')
 B.compare(s,'candidate')
 check(R.GetPlayState()&1~=0 and F.same(F.capture(tr,eqid),candidate_eq)and F.same(F.capture(master,limiter),candidate_limiter),'Live Candidate restores processing and online status without stopping')
 R.OnStopButtonEx(project)
 s=B.recover(job);check(s and not s.recovery_changed and #s.modified==2,'Restart recovers plugin originals and candidate state')
 check(B.revert(s)==0 and F.same(F.capture(tr,eqid),original_eq)and F.same(F.capture(master,limiter),original_limiter),'Revert restores both originals including initially offline limiter')
 check(R.TrackFX_GetCount(tr)==1 and R.TrackFX_GetCount(master)==1,'Revert retains existing plugin instances')

 -- Existing automated parameter: explicit override only; preserve points for revert.
 local env=R.GetFXEnvelope(tr,0,0,true);R.InsertEnvelopePoint(env,0,.25,0,0,false,true);R.InsertEnvelopePoint(env,8,.75,0,0,false,true);R.Envelope_SortPoints(env)
 local automated_eq=F.capture(tr,eqid)
 s=B.begin(job,{0,8})
 local accepted=pcall(B.execute,s,'set_effect_parameter',{track=id,effect=eqid,parameter=0,normalized=.9})
 automated_eq=s.modified[1].original -- Exact durable checkpoint after the new envelope has initialized.
 check(not accepted and F.same(F.capture(tr,eqid),automated_eq),'Automation override must be explicit and rejection leaves plugin intact')
 B.execute(s,'set_effect_parameter',{track=id,effect=eqid,parameter=0,normalized=.9,override_automation=true})
 local _,envelope=R.GetEnvelopeStateChunk(R.GetFXEnvelope(tr,0,0,false),'',false)
 log:write('Parameter readback: '..tostring(R.TrackFX_GetParamNormalized(tr,0,0))..'\n');log:flush()
 check(envelope:match('\nACT%s+0')and math.abs(R.TrackFX_GetParamNormalized(tr,0,0)-.9)<1e-5,'Full-range parameter edit suspends conflicting automation explicitly')
 local added=B.execute(s,'add_effect',{track=id,plugin='VST: ReaComp (Cockos)'})
 check(added.effect and #s.owned==1,'Added effects remain separately owned')
 check(B.revert(s)==0 and F.same(F.capture(tr,eqid),automated_eq)and R.TrackFX_GetCount(tr)==1,'Revert restores original automation and deletes only the added plugin')

 s=B.begin(job,{0,8})
 B.execute(s,'set_effect_state',{track=id,effect=eqid,enabled=false})
 R.TrackFX_SetParamNormalized(tr,0,1,.8);local manual=F.capture(tr,eqid)
 check(B.revert(s)==1 and F.same(F.capture(tr,eqid),manual),'Revert preserves a later manual edit to an existing plugin')
 log:write('RENDER '..render.path..'\n');log:flush()
end,debug.traceback)
R.SetTrackStateChunk=native_set_chunk
if project and R.ValidatePtr(project,'ReaProject*')then
 R.SelectProjectInstance(project);R.OnStopButtonEx(project)
 R.Main_SaveProjectEx(project,job..'/Existing FX.RPP',8);R.Main_OnCommand(40860,0)
end
R.SelectProjectInstance(original)
local preserved=State.capture(original)==before
log:write(preserved and 'PASS Real project audio state preserved\n'or 'FAIL Real project audio state changed\n')
log:write(ok and (passed..' native existing-plugin checks passed\n')or ('FAIL '..tostring(err)..'\n'));log:close()
dofile(root..'/Launcher/launch.lua')
