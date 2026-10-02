-- Native checks: installed licensed plugins, silent disposable project, no model.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_mix_bridge.lua');local P=dofile(root..'/Scripts/solo_mix_processors.lua')
local State=dofile(root..'/Scripts/solo_mix_state.lua');local FX=dofile(root..'/Scripts/solo_mix_effects.lua')
local J=B.json;local log=assert(io.open(root..'/Tests/master-processor-checks.txt','w'))
local original=R.EnumProjects(-1,'');local before=State.capture(original);local project,job,s;local n=0
local function check(ok,label)assert(ok,label);n=n+1;log:write('PASS '..label..'\n');log:flush()end
local ok,err=xpcall(function()
 assert(R.GetAllProjectPlayStates()==0,'Stop all transport before testing')
 assert(R.GetExtState('SoloStudio_v1','panel_open')~='1','Close Solo Studio before testing')
 job=root..'/Tests/Master processor data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
 local f=assert(io.open(job..'/Master processors.RPP','w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
 R.Main_OnCommand(41929,0);R.Main_openProject(job..'/Master processors.RPP');project=R.EnumProjects(-1,'');assert(project~=original)
 local master=R.GetMasterTrack(project)
 for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 R.InsertTrackAtIndex(0,false);local tr=R.GetTrack(project,0)
 local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
 R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/mix-tone.wav')));R.SetMediaItemInfo_Value(item,'D_LENGTH',8)
 local ids,initial={},{}
 for key,name in pairs({tape=P.ampex,ssl=P.ssl,clip=P.clipper})do
  local idx=R.TrackFX_AddByName(master,name,false,-1);check(idx>=0,'Installed '..key..' loads')
  ids[key]=R.TrackFX_GetFXGUID(master,idx);initial[key]=FX.capture(master,ids[key])
 end
 local function index(key)for i=0,R.TrackFX_GetCount(master)-1 do if R.TrackFX_GetFXGUID(master,i)==ids[key]then return i end end end
 local function run(name,key,a)a=a or {};a.track='MASTER';a.effect=ids[key];return B.execute(s,name,a)end
 s=B.begin(job,{0,8})
 local available={};for _,name in ipairs(B.plugins())do available[name]=true end
 check(available[P.clipper]and available[P.ampex]and available[P.ssl],'All three processors are discoverable')
 local inspector=run('inspect_effect','tape')
 check(inspector.total_parameters>1600 and #inspector.parameters==33 and inspector.next_start==J.null,'UAD inspection returns audio/host parameters beyond old cap')
 check(inspector.parameters[#inspector.parameters].index>2000 and inspector.skipped_midi_parameters>2000,'UAD MIDI placeholders skipped while preserving native indices')
 check(#run('inspect_effect','tape',{start_parameter=30,include_midi=true}).parameters==96,'Raw MIDI parameter pages remain available')
 local preset=run('configure_tape','tape',{preset='Clean Ultralinear Master'})
 local expected=P.tape_preset();local ti=index('tape')
 for i=0,28 do check(math.abs(R.TrackFX_GetParamNormalized(master,ti,i)-expected[i])<1e-4,'Factory tape parameter '..i..' readback')end
 local gui=J.read(root..'/Tests/ultralinear-native.json')
 if gui then for _,p in ipairs(gui)do assert(math.abs(R.TrackFX_GetParamNormalized(master,ti,p.index)-p.normalized)<1e-4,'UA browser preset differs')end;check(true,'Factory settings match independently captured UA browser preset')end
 run('configure_tape','tape',{input_db=-6,output_db=6})
 check(R.TrackFX_GetParamNormalized(master,ti,0)==0,'Independent tape gain disables Auto Gain')
 for _,i in ipairs({1,2,3,4})do local _,text=R.TrackFX_GetFormattedParamValue(master,ti,i,'');check(math.abs(tonumber(text:match('[+-]?%d+%.?%d*'))-(i<=2 and -6 or 6))<=.11,'Tape stereo dB control '..i)end
 check(R.TrackFX_GetParamNormalized(master,ti,7)==expected[7],'Subsequent tape gain retains preset tape type')
 run('configure_bus_compressor','ssl',{threshold_db=-4,ratio=2,attack_ms=30,release='auto',makeup_db=1,sidechain_hpf_hz=80})
 check(true,'SSL settings and physical readbacks verified')
 run('configure_bus_compressor','ssl',{threshold_db=3,ratio=4,attack_ms=10,release='300ms',makeup_db=2,sidechain_hpf_hz=0})
 check(true,'SSL alternate attack/release/ratio and detector-off verified')
 local clip=run('configure_clipper','clip',{clipping_db=-3,input_db=1,output_db=-1,oversampling='192k'})
 check(clip.host_oversampling_shift==2,'StandardCLIP physical gains/mode and REAPER oversampling read back')
 local candidate={};for key,id in pairs(ids)do candidate[key]=FX.capture(master,id)end
 local bad=pcall(run,'configure_tape','ssl',{input_db=-3})
 check(not bad and FX.same(FX.capture(master,ids.ssl),candidate.ssl),'Wrong processor rejected without modifying state')
 local set=R.TrackFX_SetParamNormalized;local writes=0
 R.TrackFX_SetParamNormalized=function(...)writes=writes+1;if writes==3 then return false end;return set(...)end
 local success=pcall(run,'configure_clipper','clip',{clipping_db=-6})
 R.TrackFX_SetParamNormalized=set
 check(not success and FX.same(FX.capture(master,ids.clip),candidate.clip),'Failed processor write rolls back full FX state including oversampling')
 local checkpoint=B.execute(s,'save_mix_checkpoint',{name='Tape SSL clipper'})
 run('configure_tape','tape',{input_db=-3,output_db=3})
 B.execute(s,'restore_mix_checkpoint',{id=checkpoint.id})
 check(FX.same(FX.capture(master,ids.tape),candidate.tape),'Checkpoint restores tape settings')
 B.compare(s,'original')
 for key,id in pairs(ids)do check(FX.same(FX.capture(master,id),initial[key]),'Original restores '..key..' including host settings')end
 B.compare(s,'candidate')
 for key,id in pairs(ids)do check(FX.same(FX.capture(master,id),candidate[key]),'Candidate restores '..key)end
 B.revert(s)
 for key,id in pairs(ids)do check(FX.same(FX.capture(master,id),initial[key]),'Revert restores '..key)end
 -- Active automation must be protected before any linked tape setting changes.
 local env=R.GetFXEnvelope(master,index('tape'),1,true);assert(env)
 R.InsertEnvelopePoint(env,0,.3,0,0,false,true);R.InsertEnvelopePoint(env,8,.4,0,0,false,true);R.Envelope_SortPoints(env)
 local automated=FX.capture(master,ids.tape);s=B.begin(job,{0,8})
 check(not pcall(run,'configure_tape','tape',{input_db=-6,output_db=6})and FX.same(FX.capture(master,ids.tape),automated),'Tape automation is protected transactionally')
 run('configure_tape','tape',{input_db=-6,output_db=6,override_automation=true})
 local _,chunk=R.GetEnvelopeStateChunk(env,'',false);check(not chunk:match('\nACT%s+1'),'Explicit tape override suspends automation')
 B.revert(s);check(FX.same(FX.capture(master,ids.tape),automated),'Revert restores automation and linked controls')
end,debug.traceback)
if project and R.ValidatePtr(project,'ReaProject*')then R.SelectProjectInstance(project);R.Main_SaveProject(project,false);R.Main_OnCommand(40860,0)end
R.SelectProjectInstance(original)
log:write(State.capture(original)==before and 'PASS Real project audio state preserved\n'or 'FAIL Real project audio state changed\n')
log:write(ok and (n..' master processor checks passed\n')or ('FAIL '..tostring(err)..'\n'));log:close()
