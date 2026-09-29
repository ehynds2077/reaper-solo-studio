-- Isolated native integration test: new tab, generated sine, no hardware outputs.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local root=dir:match('^(.*)/Tests$');local R=reaper
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local J=B.json
assert(R.GetPlayState()==0,'Stop transport before testing.')
local original=R.EnumProjects(-1,'');local count_before=R.GetProjectStateChangeCount(original)
local log=assert(io.open(dir..'/mix-checks.txt','w'));local passed=0
local function check(ok,label)assert(ok,label);passed=passed+1;log:write('PASS '..label..'\n');log:flush()end
R.Main_OnCommand(41929,0);local project=R.EnumProjects(-1,'')
local ok,err=xpcall(function()
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(0,0);R.GetSetMediaTrackInfo_String(tr,'P_NAME','Synthetic guitar',true)
 local master=R.GetMasterTrack(0)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 check(R.GetTrackNumSends(master,1)==0,'Test has no hardware outputs')
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 local source=assert(R.PCM_Source_CreateFromFile(dir..'/mix-tone.wav'))
 R.SetMediaItemTake_Source(take,source);R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 -- Synthetic fixtures do not pass through REAPER's normal import/peak builder.
 if R.PCM_Source_BuildPeaks(source,0)~=0 then
  local complete=false
  for i=1,1000 do if R.PCM_Source_BuildPeaks(source,1)==0 then complete=true;break end end
  R.PCM_Source_BuildPeaks(source,2);assert(complete,'Synthetic peak build did not finish')
 end
 R.SetMediaItemInfo_Value(item,'D_FADEINLEN',0);R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
 local path=dir..'/Mix test data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(path,0)
 -- Inspect the actual installed limiter before validating its physical-unit adapter.
 local limiter_name
 for _,name in ipairs(B.plugins())do if name=='VST3: Pro-L 2 (FabFilter)'then limiter_name=name end end
 if limiter_name then
  local idx=R.TrackFX_AddByName(master,limiter_name,false,-1);assert(idx>=0,'Could not load installed Pro-L 2')
  local params=J.array()
  for i=0,R.TrackFX_GetNumParams(master,idx)-1 do
   local _,name=R.TrackFX_GetParamName(master,idx,i,'');local _,formatted=R.TrackFX_GetFormattedParamValue(master,idx,i,'')
   local samples=J.array()
   for _,n in ipairs({0,.25,.5,.75,1})do local good,value=R.TrackFX_FormatParamValueNormalized(master,idx,i,n,'');samples[#samples+1]={normalized=n,ok=good,value=value}end
   params[#params+1]={index=i,name=name,formatted=formatted,samples=samples}
  end
  J.write(dir..'/limiter-parameters.json',params);R.TrackFX_Delete(master,idx)
 end
 local existing_master=R.TrackFX_AddByName(master,'VST: ReaEQ (Cockos)',false,-1)
 assert(existing_master>=0,'Test needs stock ReaEQ');local existing_master_guid=R.TrackFX_GetFXGUID(master,existing_master)
 local s=B.begin(path,{0,8});local guid=R.GetTrackGUID(tr)
 local info=B.execute(s,'inspect_project',{})
 check(#info.tracks==1 and info.tracks[1].id==guid,'Inspect project uses stable track GUID')
 J.write(path..'/plugins.json',info.available_plugins)
 local oldrender=R.GetSetProjectInfo(0,'RENDER_BOUNDSFLAG',0,false)
 local first_render=B.execute(s,'measure_mix',{})
 s=B.recover(path);local second_render=B.execute(s,'measure_mix',{})
 check(first_render.path~=second_render.path,'Recovery uses a fresh render path instead of overwriting an earlier take')
 local reused=B.execute(s,'measure_mix',{})
 check(reused.cached and reused.path==second_render.path and s.renders==1,'Unchanged mix reuses its validated render')
 local diagnostic=B.execute(s,'measure_mix',{start_seconds=2,duration_seconds=3})
 check(not diagnostic.cached and diagnostic.bounds[1]==2 and diagnostic.bounds[2]==5,'Diagnostic renders use exact requested bounds')
 local render_action=R.Main_OnCommand
 R.Main_OnCommand=function(command,flag)if command~=42230 then return render_action(command,flag)end end
 local rendered=pcall(B.execute,s,'measure_mix',{start_seconds=1,duration_seconds=3})
 R.Main_OnCommand=render_action
 check(not rendered,'Cancelled render cannot be mistaken for an older WAV')
 check(R.GetSetProjectInfo(0,'RENDER_BOUNDSFLAG',0,false)==oldrender,'Render settings restored')
 B.execute(s,'set_track_mix',{track=guid,volume_db=-6,pan=0})
 check(math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-10^(-6/20))<1e-8,'Set volume to -6 dB')
 local changed=B.execute(s,'measure_mix',{})
 check(not changed.cached and changed.path~=second_render.path,'Fader changes invalidate cached audio')
 B.execute(s,'set_track_mix',{track=guid,volume_db=18,pan=0})
 check(math.abs(20*math.log(R.GetMediaTrackInfo_Value(tr,'D_VOL'),10)-18)<1e-6,'Raw tracks can be lifted beyond the old +6 dB cap')
 B.execute(s,'set_track_mix',{track=guid,volume_db=-6,pan=0})
 local good=pcall(B.execute,s,'set_track_mix',{track=guid,volume_db=25,pan=0})
 check(not good,'Out-of-range gain rejected')
 local plugin
 for _,name in ipairs(info.available_plugins)do if name:find('ReaComp',1,true)then plugin=name;break end end
 check(plugin~=nil,'Stock compressor discovered')
 local effect=B.execute(s,'add_effect',{track=guid,plugin=plugin})
 local params=B.execute(s,'inspect_effect',{track=guid,effect=effect.effect})
 check(#params.parameters>5,'Actual compressor parameters inspected')
 J.write(path..'/compressor.json',params)
 local p=params.parameters[1]
 B.execute(s,'set_effect_parameter',{track=guid,effect=effect.effect,parameter=p.index,normalized=math.max(0,p.normalized-.1)})
 check(R.TrackFX_GetCount(tr)==1,'Compressor added to track')
 B.execute(s,'configure_compressor',{track=guid,effect=effect.effect,threshold_db=-42,ratio=12,attack_ms=10,release_ms=100,makeup_db=6})
 check(true,'Compressor physical units validated by actual formatted readback')
 local eqname;for _,name in ipairs(info.available_plugins)do if name:find('ReaEQ',1,true)then eqname=name;break end end
 local eq=B.execute(s,'add_effect',{track=guid,plugin=eqname})
 B.execute(s,'configure_eq',{track=guid,effect=eq.effect,band='bell',band_index=0,frequency_hz=1000,gain_db=-9})
 check(true,'EQ physical units validated by actual formatted readback')
 B.execute(s,'set_trim_automation',{track=guid,points={{seconds=0,db=0},{seconds=1,db=-6},{seconds=7,db=-6},{seconds=8,db=0}}})
 check(R.TrackFX_GetCount(tr)==3,'Dedicated automation trim added')
 local limiter=B.execute(s,'add_effect',{track='MASTER',plugin=assert(limiter_name,'Install FabFilter Pro-L 2 for limiter checks')})
 B.execute(s,'configure_limiter',{track='MASTER',effect=limiter.effect,gain_db=12,ceiling_db=-1.2})
 local resumed_info=B.execute(s,'inspect_project',{})
 check(#resumed_info.session_effects==4 and resumed_info.session_effects[4].id==limiter.effect,'Refinement exposes owned effect IDs including master processing')
 check(R.TrackFX_GetCount(master)==2,'Master limiter appended after existing master FX')
 local _,gain=R.TrackFX_GetFormattedParamValue(master,1,0,'');local _,ceiling=R.TrackFX_GetFormattedParamValue(master,1,18,'')
 check(gain=='+12.00 dB'and ceiling=='-1.20 dBTP','Limiter gain and true-peak ceiling use verified physical units')
 good=pcall(B.execute,s,'configure_limiter',{track='MASTER',effect=limiter.effect,gain_db=12,ceiling_db=0})
 check(not good,'Limiter rejects output ceiling above -1 dBTP')
 B.execute(s,'measure_mix',{})
 B.compare(s,'original')
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1 and not R.TrackFX_GetEnabled(tr,0)and not R.TrackFX_GetEnabled(tr,1),'Original comparison restores level and bypasses added FX')
 check(R.TrackFX_GetEnabled(master,0)and not R.TrackFX_GetEnabled(master,1),'Original bypasses owned master FX only')
 B.compare(s,'candidate')
 check(R.TrackFX_GetEnabled(tr,0)and R.TrackFX_GetEnabled(tr,1),'Candidate comparison restores added FX')
 check(R.TrackFX_GetEnabled(master,1),'Candidate restores master processing')
 B.execute(s,'measure_track',{track=guid})
 check(R.GetMediaTrackInfo_Value(tr,'I_SOLO')==0,'Track contribution measurement restores solo state')
 R.SetMediaTrackInfo_Value(tr,'D_PAN',.3)
 good=pcall(B.execute,s,'set_track_mix',{track=guid,volume_db=-5,pan=0})
 check(not good,'External project edit stops model mutations')
 local conflicts=B.revert(s)
 check(conflicts==1 and R.GetMediaTrackInfo_Value(tr,'D_PAN')==.3,'Revert preserves a manual pan edit')
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1 and R.TrackFX_GetCount(tr)==0,'Revert restores fader and removes only session FX')
 check(R.TrackFX_GetCount(master)==1 and R.TrackFX_GetFXGUID(master,0)==existing_master_guid,'Revert preserves existing master FX')
 check(R.CountMediaItems(0)==1 and R.GetMediaItemInfo_Value(item,'D_LENGTH')==8,'Audio item untouched')
 R.RecursiveCreateDirectory(path..'/recovery',0)
 local s2=B.begin(path..'/recovery',{0,8})
 B.execute(s2,'set_track_mix',{track=guid,volume_db=-4,pan=.3})
 local recovered=B.recover(s2.path)
 check(recovered~=nil,'Unfinished session journal can be recovered')
 B.revert(recovered)
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1,'Recovered journal restores original level')
 -- Long-song benchmark in this disposable project, using looped synthetic audio.
 local loops=R.GetMediaItemInfo_Value(item,'B_LOOPSRC')
 R.SetMediaItemInfo_Value(item,'B_LOOPSRC',1);R.SetMediaItemInfo_Value(item,'D_LENGTH',274)
 R.RecursiveCreateDirectory(path..'/performance',0)
 local perf=B.begin(path..'/performance',{0,274})
 local full=B.execute(perf,'measure_mix',{})
 local short=B.execute(perf,'measure_mix',{start_seconds=120,duration_seconds=30})
 local cached=B.execute(perf,'measure_mix',{start_seconds=120,duration_seconds=30})
 check(cached.cached and cached.path==short.path and perf.renders==2,'Repeated diagnostics skip rendering')
 local solo=B.execute(perf,'measure_track',{track=guid,start_seconds=120,duration_seconds=30})
 check(not solo.cached and solo.path~=short.path,'Track and mix caches are separate')
 check(R.GetMediaTrackInfo_Value(tr,'I_SOLO')==0,'Diagnostic solo render restores track solo')
 local whole=B.execute(perf,'measure_mix',{})
 check(whole.cached and whole.path==full.path and whole.bounds[2]==274,'Final full-passage check never reuses a short diagnostic')
 local count=perf.renders
 check(not pcall(B.execute,perf,'measure_mix',{start_seconds=270,duration_seconds=30})and perf.renders==count,'Out-of-passage diagnostics are rejected before rendering')
 check(not pcall(B.execute,perf,'measure_mix',{start_seconds=120})and perf.renders==count,'Incomplete diagnostic bounds are rejected')
 B.compare(perf,'original');B.compare(perf,'candidate')
 check(not B.execute(perf,'measure_mix',{start_seconds=120,duration_seconds=30}).cached,'A/B changes invalidate cached audio')
 B.execute(perf,'add_effect',{track=guid,plugin=eqname})
 check(not B.execute(perf,'measure_mix',{start_seconds=120,duration_seconds=30}).cached,'Effect changes invalidate cached audio')
 local benchmark={full_seconds=full.render_seconds,diagnostic_seconds=short.render_seconds,
  reused_seconds=cached.render_seconds,full_path=full.path,diagnostic_path=short.path}
 J.write(dir..'/mix-performance.json',benchmark)
 log:write(string.format('BENCHMARK 274s render %.3fs; 30s render %.3fs; repeated render skipped\n',full.render_seconds,short.render_seconds))
 B.revert(perf)
 R.SetMediaItemInfo_Value(item,'B_LOOPSRC',loops);R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 -- Source overview uses the peak cache at absolute project times, with no render.
 local overview=dofile(root..'/Scripts/solo_mix_visuals.lua')
 R.SetMediaItemInfo_Value(item,'D_POSITION',40)
 local before=R.GetProjectStateChangeCount(project)
 local source_view=overview.overview(project,{0,60},{start_track=0,track_count=16})
 local row=source_view.tracks[1];local maximum=0
 for _,peak in ipairs(row.peaks)do maximum=math.max(maximum,peak)end
 J.write(dir..'/mix-source-overview.json',source_view)
 log:write('PEAKS '..maximum..' '..tostring(row.clips[1]and row.clips[1].kind)..'\n');log:flush()
 check(#row.clips==1 and row.clips[1].start_seconds==40,'Source overview places clips at absolute project times')
 check(maximum>0 and row.clips[1].kind=='audio','Native source peak cache supplies waveform data at a nonzero item position')
 check(R.GetProjectStateChangeCount(project)==before,'Source overview is read-only')
 R.SetMediaItemInfo_Value(item,'B_MUTE',1)
 check(#overview.overview(project,{0,60},{}).tracks[1].clips==0,'Muted clips are excluded from source overview')
 R.SetMediaItemInfo_Value(item,'B_MUTE',0);R.SetMediaItemInfo_Value(item,'D_POSITION',0)
end,debug.traceback)
local function cleanup()
 -- Only the disposable test project is saved to avoid a close-tab save prompt.
 R.Main_SaveProjectEx(project,dir..'/Mix checks.RPP',8)
 R.Main_OnCommand(40860,0);R.SelectProjectInstance(original)
 check(R.GetProjectStateChangeCount(original)==count_before,'Original user project unchanged')
 if not ok then log:write('FAIL '..err..'\n')end
 log:write(tostring(passed)..' native mix checks passed\n');log:close()
 if not ok then R.ShowMessageBox(err,'Mix integration test',0)end
end
if not ok then cleanup();return end
local job=dir..'/Mix test data/worker-'..R.genGuid():gsub('[^%w]','')
R.RecursiveCreateDirectory(job,0)
local session=B.begin(job,{0,8})
J.write(job..'/config.json',{bounds={0,8},rounds=4,direction='Synthetic test only'})
R.ExecProcess('/usr/bin/python3 -B "'..root..'/Mix/test_native_worker.py" "'..job..'"',-1)
local handled='';local deadline=R.time_precise()+180
local function tick()
 local safe,why=xpcall(function()
  local request=J.read(job..'/request.json')
  if request and request.id~=handled then
   handled=request.id
   local accepted,result=pcall(B.execute,session,request.name,request.arguments)
   J.write(job..'/response-'..request.id..'.json',accepted and {result=result}or {error=tostring(result),fatal=true})
  end
  local result=J.read(job..'/test-result.json')
  if result then
   check(result.ok,'Full Python worker / native bridge / render / analysis loop: '..tostring(result.error or 'ok'))
   log:write('MEASURED '..result.original_lufs..' -> '..result.candidate_lufs..' LUFS\n')
   B.revert(session);cleanup();return
  end
  assert(R.time_precise()<deadline,'Worker integration timed out')
  R.defer(tick)
 end,debug.traceback)
 if not safe then ok=false;err=why;pcall(B.revert,session);cleanup()end
end
tick()
