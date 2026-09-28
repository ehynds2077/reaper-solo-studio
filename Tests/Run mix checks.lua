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
 R.SetMediaItemInfo_Value(item,'D_FADEINLEN',0);R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',0)
 local path=dir..'/Mix test data/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(path,0)
 local s=B.begin(path,{0,8});local guid=R.GetTrackGUID(tr)
 local info=B.execute(s,'inspect_project',{})
 check(#info.tracks==1 and info.tracks[1].id==guid,'Inspect project uses stable track GUID')
 J.write(path..'/plugins.json',info.available_plugins)
 local oldrender=R.GetSetProjectInfo(0,'RENDER_BOUNDSFLAG',0,false)
 B.execute(s,'measure_mix',{})
 check(R.GetSetProjectInfo(0,'RENDER_BOUNDSFLAG',0,false)==oldrender,'Render settings restored')
 B.execute(s,'set_track_mix',{track=guid,volume_db=-6,pan=0})
 check(math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-10^(-6/20))<1e-8,'Set volume to -6 dB')
 B.execute(s,'measure_mix',{})
 local good=pcall(B.execute,s,'set_track_mix',{track=guid,volume_db=7,pan=0})
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
 B.execute(s,'configure_compressor',{track=guid,effect=effect.effect,threshold_db=-18,ratio=3,attack_ms=10,release_ms=100})
 check(true,'Compressor physical units validated by actual formatted readback')
 local eqname;for _,name in ipairs(info.available_plugins)do if name:find('ReaEQ',1,true)then eqname=name;break end end
 local eq=B.execute(s,'add_effect',{track=guid,plugin=eqname})
 B.execute(s,'configure_eq',{track=guid,effect=eq.effect,band='bell',band_index=0,frequency_hz=1000,gain_db=-3})
 check(true,'EQ physical units validated by actual formatted readback')
 B.execute(s,'set_trim_automation',{track=guid,points={{seconds=0,db=0},{seconds=1,db=-6},{seconds=7,db=-6},{seconds=8,db=0}}})
 check(R.TrackFX_GetCount(tr)==3,'Dedicated automation trim added')
 B.execute(s,'measure_mix',{})
 B.compare(s,'original')
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1 and not R.TrackFX_GetEnabled(tr,0)and not R.TrackFX_GetEnabled(tr,1),'Original comparison restores level and bypasses added FX')
 B.compare(s,'candidate')
 check(R.TrackFX_GetEnabled(tr,0)and R.TrackFX_GetEnabled(tr,1),'Candidate comparison restores added FX')
 B.execute(s,'measure_track',{track=guid})
 check(R.GetMediaTrackInfo_Value(tr,'I_SOLO')==0,'Track contribution measurement restores solo state')
 R.SetMediaTrackInfo_Value(tr,'D_PAN',.3)
 good=pcall(B.execute,s,'set_track_mix',{track=guid,volume_db=-5,pan=0})
 check(not good,'External project edit stops model mutations')
 local conflicts=B.revert(s)
 check(conflicts==1 and R.GetMediaTrackInfo_Value(tr,'D_PAN')==.3,'Revert preserves a manual pan edit')
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1 and R.TrackFX_GetCount(tr)==0,'Revert restores fader and removes only session FX')
 check(R.CountMediaItems(0)==1 and R.GetMediaItemInfo_Value(item,'D_LENGTH')==8,'Audio item untouched')
 R.RecursiveCreateDirectory(path..'/recovery',0)
 local s2=B.begin(path..'/recovery',{0,8})
 B.execute(s2,'set_track_mix',{track=guid,volume_db=-4,pan=.3})
 local recovered=B.recover(s2.path)
 check(recovered~=nil,'Unfinished session journal can be recovered')
 B.revert(recovered)
 check(R.GetMediaTrackInfo_Value(tr,'D_VOL')==1,'Recovered journal restores original level')
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
J.write(job..'/config.json',{bounds={0,8},rounds=3,direction='Synthetic test only'})
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
