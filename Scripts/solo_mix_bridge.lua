-- Main-thread REAPER tools for the local worker. No model-provided code execution.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
local R=reaper
local B={json=J}
local function finite(v,lo,hi)assert(type(v)=='number'and v==v and v>=lo and v<=hi,'Value outside allowed range');return v end
local function db(v)return v>0 and 20*math.log(v,10)or -150 end
local function track(guid,proj)
 if guid=='MASTER'then return R.GetMasterTrack(proj)end
 for i=0,R.CountTracks(proj)-1 do local tr=R.GetTrack(proj,i);if R.GetTrackGUID(tr)==guid then return tr end end
 error('Track no longer exists')
end
local function fx_index(tr,guid)
 for i=0,R.TrackFX_GetCount(tr)-1 do if R.TrackFX_GetFXGUID(tr,i)==guid then return i end end
 error('Effect no longer exists')
end
local function active_envelope(tr,key)
 local env=R.GetTrackEnvelopeByChunkName(tr,key)
 if not env then return false end
 local ok,chunk=R.GetEnvelopeStateChunk(env,'',false)
 return not ok or chunk:match('\nACT%s+1')~=nil
end
local function list_tracks(proj,bounds)
 local out=J.array()
 for i=0,R.CountTracks(proj)-1 do
  local tr=R.GetTrack(proj,i);local _,name=R.GetTrackName(tr)
  local parent=R.GetParentTrack(tr);local fx=J.array();local sends=J.array()
  for n=0,R.TrackFX_GetCount(tr)-1 do local _,label=R.TrackFX_GetFXName(tr,n,'');fx[#fx+1]={name=label,enabled=R.TrackFX_GetEnabled(tr,n)}end
  for n=0,R.GetTrackNumSends(tr,0)-1 do
   local dest=R.GetTrackSendInfo_Value(tr,0,n,'P_DESTTRACK')
   sends[#sends+1]={destination=dest and R.GetTrackGUID(dest)or '',volume_db=db(R.GetTrackSendInfo_Value(tr,0,n,'D_VOL'))}
  end
  local playing_items
  if bounds then
   playing_items=0;local fixed=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')>0
   for n=0,R.CountTrackMediaItems(tr)-1 do
    local item=R.GetTrackMediaItem(tr,n);local pos=R.GetMediaItemInfo_Value(item,'D_POSITION')
    local lane=R.GetMediaItemInfo_Value(item,'C_LANEPLAYS')
    if pos<bounds[2]and pos+R.GetMediaItemInfo_Value(item,'D_LENGTH')>bounds[1]
     and R.GetMediaItemInfo_Value(item,'B_MUTE')==0 and lane~=-1 and (not fixed or lane>0)then playing_items=playing_items+1 end
   end
  end
  out[#out+1]={id=R.GetTrackGUID(tr),name=name,volume_db=db(R.GetMediaTrackInfo_Value(tr,'D_VOL')),
   pan=R.GetMediaTrackInfo_Value(tr,'D_PAN'),pan_mode=R.GetMediaTrackInfo_Value(tr,'I_PANMODE'),
   muted=R.GetMediaTrackInfo_Value(tr,'B_MUTE')~=0,solo=R.GetMediaTrackInfo_Value(tr,'I_SOLO')~=0,
   items=R.CountTrackMediaItems(tr),playing_items_in_passage=playing_items,parent=parent and R.GetTrackGUID(parent)or '',sends=sends,
   volume_automated=active_envelope(tr,'<VOLENV2'),pan_automated=active_envelope(tr,'<PANENV2'),effects=fx}
 end
 return out
end
function B.plugins()
 local result=J.array();local seen={}
 for i=0,10000 do
  local ok,name=R.EnumInstalledFX(i);if not ok then break end
  if name:find('ReaEQ',1,true)or name:find('ReaComp',1,true)or name:find('FabFilter',1,true)or name:find('UADx',1,true)then
   -- Prefer VST3 or stock VST; omit AU duplicates, instruments and DSP-only UAD.
   if (name:match('^VST3:')or name:match('^VST:'))and not seen[name]then result[#result+1]=name;seen[name]=true end
  end
 end
 return result
end
function B.diagnostics(s)
 local project,path=R.EnumProjects(-1,'')
 local offline_inactive
 if R.get_config_var_string then local ok,value=R.get_config_var_string('offlineinact');if ok then offline_inactive=value~='0'end end
 local out={time=os.time(),project_path=path,transport=R.GetPlayState(),
  media_offline_when_inactive=offline_inactive,
  engine_running=R.Audio_IsRunning and R.Audio_IsRunning()~=0,
  all_project_transport=R.GetAllProjectPlayStates and R.GetAllProjectPlayStates()or nil,
  project_version=R.GetProjectStateChangeCount(project),expected_version=s and s.version,
  undo_label=R.Undo_CanUndo2 and R.Undo_CanUndo2(project),
  session_project_path=s and s.project_path,mode=s and s.mode,render_count=s and s.renders}
 if R.GetMasterTrack and R.TrackFX_GetCount then
  local master=R.GetMasterTrack(project);local effects=J.array()
  for i=0,R.TrackFX_GetCount(master)-1 do
   local _,name=R.TrackFX_GetFXName(master,i,'')
   effects[#effects+1]={name=name,enabled=R.TrackFX_GetEnabled(master,i),offline=R.TrackFX_GetOffline and R.TrackFX_GetOffline(master,i)}
  end
  out.master={muted=R.GetMediaTrackInfo_Value(master,'B_MUTE')~=0,volume=R.GetMediaTrackInfo_Value(master,'D_VOL'),effects=effects}
 end
 return out
end
function B.trace(s,kind,details)
 local ok,err=pcall(function()
  local f=assert(io.open(s.path..'/bridge-events.jsonl','a'))
  f:write(J.encode({time=os.time(),kind=kind,details=details}), '\n');f:close()
 end)
 return ok,err
end
local function journal(s)
 J.write(s.path..'/snapshot.json',{original=s.original,owned=s.owned,bounds=s.bounds,expected=s.expected,
  candidate=s.candidate,mode=s.mode,finished=s.finished or false,project_path=s.project_path,resolution=s.resolution})
end
local function remember(s)
 s.expected={}
 for _,row in ipairs(s.original)do
  local tr=track(row.id,s.project)
  s.expected[row.id]={volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),pan=R.GetMediaTrackInfo_Value(tr,'D_PAN')}
 end
 s.version=R.GetProjectStateChangeCount(s.project);journal(s)
end
function B.begin(path,bounds)
 assert(R.GetPlayState()==0,'Stop playback before mixing.')
 assert(R.CountTracks(0)>0 and R.CountMediaItems(0)>0,'Record or import audio before mixing.')
 local p,name=R.EnumProjects(-1,'');local original=J.array()
 for _,row in ipairs(list_tracks(p))do
  assert(not row.solo,'Clear track solos before mixing.')
  local tr=track(row.id,p)
  original[#original+1]={id=row.id,volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),pan=row.pan}
 end
 local s={path=path,project=p,project_path=name,original=original,owned=J.array(),bounds=bounds,mode='candidate',renders=0}
 remember(s);return s
end
function B.recover(path)
 local data=J.read(path..'/snapshot.json');if not data or data.finished then return nil end
 local p,name=R.EnumProjects(-1,'')
 if name~=data.project_path then return nil end
 -- Track edits do not change ownership of a saved project. Unsaved tabs need
 -- matching GUIDs because they all have the same empty filename.
 local changed=#data.original~=R.CountTracks(p)
 if name==''and #data.original==0 then return nil end
 for _,row in ipairs(data.original)do
  local ok,tr=pcall(track,row.id,p)
  if not ok and name==''then return nil end
  local expected=data.expected and data.expected[row.id]
  if not ok or not expected then changed=true
  elseif math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-expected.volume)>1e-9 or
   math.abs(R.GetMediaTrackInfo_Value(tr,'D_PAN')-expected.pan)>1e-9 then changed=true end
 end
 for _,row in ipairs(data.owned)do
  local ok=pcall(function()return fx_index(track(row.track,p),row.id)end)
  if not ok then changed=true end
 end
 data.path=path;data.project=p;data.version=R.GetProjectStateChangeCount(p);data.renders=0
 data.recovery_changed=changed
 B.trace(data,'checkpoint_recovered',B.diagnostics(data))
 return data
end
function B.find_session(root,legacy)
 -- Journals already record their owning project. Discover them per project;
 -- a single global pointer cannot represent several unfinished song mixes.
 local _,name=R.EnumProjects(-1,'');local candidates={};local seen={}
 local function consider(path)
  if not path or path==''or seen[path]then return end;seen[path]=true
  local ok,data=pcall(J.read,path..'/snapshot.json')
  if not ok or type(data)~='table'or data.finished or data.project_path~=name then return end
  local good,status=pcall(J.read,path..'/status.json')
  local updated=good and type(status)=='table'and tonumber(status.updated)or 0
  candidates[#candidates+1]={path=path,updated=updated or 0}
 end
 consider(legacy) -- Keep old installations recoverable, including custom paths.
 R.EnumerateSubdirectories(root,-1)
 local i=0
 while true do
  local folder=R.EnumerateSubdirectories(root,i);if not folder then break end
  consider(root..'/'..folder);i=i+1
 end
 table.sort(candidates,function(a,b)if a.updated~=b.updated then return a.updated>b.updated end;return a.path>b.path end)
 for _,row in ipairs(candidates)do
  -- Recovery also checks track GUIDs for unsaved tabs and detects stale edits.
  local recovered=B.recover(row.path)
  if recovered then return recovered end
 end
end
function B.guard(s,check_version,allow_playback)
 assert(R.EnumProjects(-1,'')==s.project,'Project switched. Session stopped; return to its project to revert.')
 local transport=R.GetPlayState()
 assert(transport&4==0,'Finish recording before changing the mix.')
 assert(allow_playback or transport==0,'Stop playback before continuing the mixing pass.')
 if check_version then
  assert(not s.recovery_changed,'Project changed since this mix. Start a new mix from the current sound, or revert the previous pass.')
  assert(R.GetProjectStateChangeCount(s.project)==s.version,'Project was edited outside the mixer. Session stopped; review or revert its changes.')
  for id,expected in pairs(s.expected)do
   local tr=track(id,s.project)
   assert(math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-expected.volume)<1e-9 and math.abs(R.GetMediaTrackInfo_Value(tr,'D_PAN')-expected.pan)<1e-9,'A fader or pan was changed outside the mixer. Revert preserves that edit.')
  end
 end
end
local function own(s,guid,effect)
 local tr=track(guid,s.project)
 for _,row in ipairs(s.owned)do if row.track==guid and row.id==effect then return tr,fx_index(tr,effect),row end end
 error('Only effects added by this session can be changed')
end
function B.inspect(s)
 local regions=J.array()
 for i=0,10000 do local ok,isregion,start,ending,name=R.EnumProjectMarkers3(s.project,i);if ok==0 then break end
  if isregion then regions[#regions+1]={name=name,start_seconds=start,end_seconds=ending}end
 end
 local master=R.GetMasterTrack(s.project);local effects=J.array()
 for i=0,R.TrackFX_GetCount(master)-1 do local _,name=R.TrackFX_GetFXName(master,i,'');effects[#effects+1]={name=name,enabled=R.TrackFX_GetEnabled(master,i)}end
 local trims=J.array()
 for _,row in ipairs(s.owned)do if row.trim then
  local tr=track(row.track,s.project);local idx=fx_index(tr,row.id)
  local env=R.GetFXEnvelope(tr,idx,0,false);local points=J.array()
  if env then for i=0,R.CountEnvelopePointsEx(env,-1)-1 do
   local ok,seconds,value=R.GetEnvelopePointEx(env,-1,i)
   if ok then points[#points+1]={seconds=seconds,db=value}end
  end end
  trims[#trims+1]={track=row.track,effect=row.id,points=points}
 end end
 return {tracks=list_tracks(s.project,s.bounds),regions=regions,available_plugins=B.plugins(),bounds=s.bounds,session_effects=s.owned,trim_envelopes=trims,
  capabilities={mix_tools_version=3,arrangement_peaks=true,measurement_windows=true,measurement_cache=true,silent_render_recovery=true,master_effects=true,track_max_db=24,eq_max_db=12,compressor_makeup_max_db=6,limiter_gain_max_db=24},
  master={id='MASTER',effects=effects,volume_db=db(R.GetMediaTrackInfo_Value(master,'D_VOL'))},
  master_volume_db=db(R.GetMediaTrackInfo_Value(master,'D_VOL'))}
end
local function measurement_bounds(s,a)
 if a.start_seconds==nil and a.duration_seconds==nil then return {s.bounds[1],s.bounds[2]}end
 local start=finite(a.start_seconds,s.bounds[1],s.bounds[2])
 local duration=finite(a.duration_seconds,3,s.bounds[2]-s.bounds[1])
 assert(start+duration<=s.bounds[2]+1e-7,'Measurement must stay within the selected passage')
 return {start,math.min(start+duration,s.bounds[2])}
end
local function render(s,bounds,scope)
 s.render_cache=s.render_cache or {}
 local key=scope..':'..string.format('%.17g:%.17g',bounds[1],bounds[2])
 local cached=s.render_cache[key]
 if cached then
  local f=io.open(cached.path,'rb');local size=f and f:seek('end');if f then f:close()end
  if size==cached.size then return {path=cached.path,bounds=bounds,cached=true,render_seconds=0}end
  s.render_cache[key]=nil
 end
 s.renders=s.renders+1;assert(s.renders<=160,'Render limit reached')
 local started=R.time_precise()
 local numbers={RENDER_SETTINGS=0,RENDER_BOUNDSFLAG=0,RENDER_STARTPOS=bounds[1],RENDER_ENDPOS=bounds[2],
  RENDER_CHANNELS=2,RENDER_TAILFLAG=0,RENDER_ADDTOPROJ=0,RENDER_DITHER=0,RENDER_NORMALIZE=0,RENDER_SRATE=48000}
 -- A recovered bridge starts its counter again. Unique names also make a cancelled
 -- render fail instead of accidentally accepting an earlier WAV as fresh analysis.
 local pattern='render-'..s.renders..'-'..R.genGuid():gsub('[^%w]','')
 local strings={RENDER_FORMAT='ZXZhdxgAAA==',RENDER_FORMAT2='',RENDER_FILE=s.path,RENDER_PATTERN=pattern}
 local oldn,olds={},{}
 for k in pairs(numbers)do oldn[k]=R.GetSetProjectInfo(s.project,k,0,false)end
 for k in pairs(strings)do local _,v=R.GetSetProjectInfo_String(s.project,k,'',false);olds[k]=v end
 local ok,err=xpcall(function()
  -- The offline-inactive preference can close source media between agent calls.
  -- Programmatic render does not reliably reopen it, although pressing Play does.
  -- Bring this project's media online for the render; leave the preference alone.
  R.Main_OnCommand(40101,0) -- Item: Set all media online.
  B.trace(s,'render_media_online',{render=pattern})
  for k,v in pairs(numbers)do R.GetSetProjectInfo(s.project,k,v,true)end
  for k,v in pairs(strings)do R.GetSetProjectInfo_String(s.project,k,v,true)end
  B.trace(s,'render_started',{render=pattern,bounds=bounds,scope=scope,context=B.diagnostics(s)})
  R.Main_OnCommand(42230,0)
  B.trace(s,'render_returned',{render=pattern,elapsed=R.time_precise()-started,context=B.diagnostics(s)})
 end,debug.traceback)
 for k,v in pairs(oldn)do R.GetSetProjectInfo(s.project,k,v,true)end
 for k,v in pairs(olds)do R.GetSetProjectInfo_String(s.project,k,v,true)end
 remember(s);if not ok then error(err)end
 local path=s.path..'/'..pattern..'.wav';local f=io.open(path,'rb');assert(f,'Render was cancelled or no WAV was created');local n=f:seek('end');f:close();assert(n>100,'Render is empty')
 local source=assert(R.PCM_Source_CreateFromFile(path),'Rendered WAV could not be opened')
 local duration=R.GetMediaSourceLength(source);R.PCM_Source_Destroy(source)
 assert(math.abs(duration-(bounds[2]-bounds[1]))<=.1,'Render was cancelled or incomplete')
 s.render_cache[key]={path=path,size=n}
 return {path=path,bounds=bounds,cached=false,render_seconds=R.time_precise()-started}
end
function B.execute(s,name,a)
 B.guard(s,true);assert(s.mode=='candidate','Return to Candidate before continuing');a=a or {}
 if name=='inspect_project'then return B.inspect(s)end
 -- Internal worker controls, deliberately absent from the model's tool schema.
 if name=='discard_measurements'then s.render_cache={};return {discarded=true}end
 if name=='recover_silent_render'then
  assert(R.GetAllProjectPlayStates()==0,'Stop transport in every project before recovering the audio engine')
  s.render_cache={}
  -- Reinitialize the engine without changing devices, plugins, faders or media.
  -- Audio_Init returns no value; Audio_IsRunning is the actual readiness check.
  B.trace(s,'engine_restart_started',B.diagnostics(s))
  R.Audio_Quit();R.Audio_Init()
  B.trace(s,'engine_restart_finished',B.diagnostics(s))
  remember(s)
  assert(R.Audio_IsRunning()~=0,'Audio device could not restart. Check REAPER Audio Device settings before continuing')
  return {restarted=true}
 end
 if name=='inspect_arrangement'then return dofile(dir..'/solo_mix_visuals.lua').overview(s.project,s.bounds,a)end
 if name=='measure_mix'then return render(s,measurement_bounds(s,a),'mix')end
 if name=='measure_track'then
  assert(a.track~='MASTER','Use measure_mix to measure the master output')
  local tr=track(a.track,s.project);assert(R.GetMediaTrackInfo_Value(tr,'B_MUTE')==0,'Track is muted')
  local bounds=measurement_bounds(s,a)
  local solos={};for i=0,R.CountTracks(s.project)-1 do local t=R.GetTrack(s.project,i);solos[i]={track=t,value=R.GetMediaTrackInfo_Value(t,'I_SOLO')};R.SetMediaTrackInfo_Value(t,'I_SOLO',0)end
  R.SetMediaTrackInfo_Value(tr,'I_SOLO',2)
  local ok,result=xpcall(function()return render(s,bounds,'track:'..a.track)end,debug.traceback)
  for _,row in pairs(solos)do R.SetMediaTrackInfo_Value(row.track,'I_SOLO',row.value)end
  remember(s);if not ok then error(result)end
  result.scope='Solo-in-place contribution including routing, shared returns and master FX';return result
 end
 -- Any attempted audio edit invalidates all contributions: shared buses and
 -- nonlinear master FX make per-track-only invalidation unsafe. Failed tools
 -- may have partially changed a plugin, so invalidate before applying them.
 if name~='inspect_effect'then s.render_cache={}end
 R.Undo_BeginBlock2(s.project)
 local ok,result=xpcall(function()
  if name=='set_track_mix'then
   local tr=track(a.track,s.project);local baseline
   for _,row in ipairs(s.original)do if row.id==a.track then baseline=row end end
   assert(baseline,'Unknown original track; master fader is read-only');finite(a.volume_db,-90,24);finite(a.pan,-1,1)
   assert(not active_envelope(tr,'<VOLENV2')and not active_envelope(tr,'<PANENV2'),'Existing volume/pan automation is protected; use trim automation instead')
   local _,_,_,mode=R.GetTrackUIPan(tr);assert(mode==0 or mode==3,'Dual/stereo pan tracks require manual adjustment')
   R.SetMediaTrackInfo_Value(tr,'D_VOL',10^(a.volume_db/20));R.SetMediaTrackInfo_Value(tr,'D_PAN',a.pan)
   return {volume_db=db(R.GetMediaTrackInfo_Value(tr,'D_VOL')),pan=R.GetMediaTrackInfo_Value(tr,'D_PAN')}
  elseif name=='add_effect'then
   assert(#s.owned<24,'Effect limit reached');local allowed=false
   for _,plugin in ipairs(B.plugins())do if a.plugin==plugin then allowed=true end end
   assert(allowed,'Plugin is not on the installed allowlist');local tr=track(a.track,s.project)
   local idx=R.TrackFX_AddByName(tr,a.plugin,false,-1);assert(idx>=0,'Plugin could not be loaded')
   local id=R.TrackFX_GetFXGUID(tr,idx);s.owned[#s.owned+1]={track=a.track,id=id,plugin=a.plugin}
   journal(s);return {effect=id,plugin=a.plugin,next_step='Inspect parameter names and formatted values before changing anything.'}
  elseif name=='inspect_effect'then
   local tr,idx=own(s,a.track,a.effect);local params=J.array()
   assert(R.TrackFX_GetNumParams(tr,idx)<=1600,'Plugin has too many parameters for this adapter')
   local start=a.start_parameter or 0;finite(start,0,R.TrackFX_GetNumParams(tr,idx)-1);assert(start%1==0,'Integer parameter offset required')
   for i=start,math.min(start+95,R.TrackFX_GetNumParams(tr,idx)-1) do
    local _,label=R.TrackFX_GetParamName(tr,idx,i,'');local _,formatted=R.TrackFX_GetFormattedParamValue(tr,idx,i,'')
    local raw,lo,hi=R.TrackFX_GetParam(tr,idx,i)
    params[#params+1]={index=i,name=label,formatted=formatted,raw=raw,min=lo,max=hi,normalized=R.TrackFX_GetParamNormalized(tr,idx,i)}
   end
   return {parameters=params,total_parameters=R.TrackFX_GetNumParams(tr,idx),next_start=(start+#params<R.TrackFX_GetNumParams(tr,idx))and (start+#params)or J.null}
  elseif name=='configure_compressor'then
   local tr,idx,row=own(s,a.track,a.effect);assert(row.plugin:find('ReaComp',1,true),'This adapter requires ReaComp')
   finite(a.threshold_db,-60,0);finite(a.ratio,1,20);finite(a.attack_ms,.1,200);finite(a.release_ms,10,3000)
   local makeup=finite(a.makeup_db or 0,0,6)
   local values={{0,'Threshold',10^(a.threshold_db/20)/2,a.threshold_db},{1,'Ratio',(a.ratio-1)/99,a.ratio},
    {2,'Attack',a.attack_ms/500,a.attack_ms},{3,'Release',a.release_ms/5000,a.release_ms},
    {10,'Dry',0},{11,'Wet',10^(makeup/20)/2,makeup},{15,'Auto Make Up Gain',0}}
   for _,v in ipairs(values)do local _,label=R.TrackFX_GetParamName(tr,idx,v[1],'');assert(label==v[2],'ReaComp parameter layout differs from the validated adapter')end
   local old={};for _,v in ipairs(values)do old[v[1]]=R.TrackFX_GetParamNormalized(tr,idx,v[1])end
   local good,why=pcall(function()
    for _,v in ipairs(values)do
     assert(R.TrackFX_SetParamNormalized(tr,idx,v[1],v[3]),'ReaComp rejected a parameter')
     if v[4]then local _,formatted=R.TrackFX_GetFormattedParamValue(tr,idx,v[1],'');local readback=tonumber(formatted);assert(readback and math.abs(readback-v[4])<=.11,'ReaComp unit conversion did not match readback')end
    end
   end)
   if not good then for i,v in pairs(old)do R.TrackFX_SetParamNormalized(tr,idx,i,v)end;error(why)end
   return {threshold_db=a.threshold_db,ratio=a.ratio,attack_ms=a.attack_ms,release_ms=a.release_ms,makeup_db=makeup}
  elseif name=='configure_limiter'then
   local tr,idx,row=own(s,a.track,a.effect)
   assert(row.plugin=='VST3: Pro-L 2 (FabFilter)'or row.plugin=='VST: FabFilter Pro-L 2 (FabFilter)','This adapter requires FabFilter Pro-L 2')
   finite(a.gain_db,0,24);finite(a.ceiling_db,-12,-1)
   -- Calibrated on installed Pro-L 2. Verify labels and physical readbacks before accepting changes.
   local values={{0,'Gain',a.gain_db/30,a.gain_db},{10,'True Peak Limiting',1,'On'},
    {15,'Unity Gain',0,'Off'},{17,'Bypass',0,'Not Bypassed'},
    {18,'Output Level',(a.ceiling_db+30)/30,a.ceiling_db},{9,'Oversampling',.25,'2x'}}
   local old={}
   for _,v in ipairs(values)do
    local _,label=R.TrackFX_GetParamName(tr,idx,v[1],'');assert(label==v[2],'Pro-L 2 parameter layout differs from the validated adapter')
    assert(not R.GetFXEnvelope(tr,idx,v[1],false),'Automated limiter parameters are protected')
    old[v[1]]=R.TrackFX_GetParamNormalized(tr,idx,v[1])
   end
   local good,why=pcall(function()
    for _,v in ipairs(values)do
     assert(R.TrackFX_SetParamNormalized(tr,idx,v[1],v[3]),'Pro-L 2 rejected a parameter')
     local _,formatted=R.TrackFX_GetFormattedParamValue(tr,idx,v[1],'')
     if type(v[4])=='number'then
      local actual=tonumber(formatted:match('[+-]?[%d%.]+'));assert(actual and math.abs(actual-v[4])<=.02,'Limiter dB value did not match readback')
     else assert(formatted==v[4],'Limiter mode did not match readback')end
    end
   end)
   if not good then for i,v in pairs(old)do R.TrackFX_SetParamNormalized(tr,idx,i,v)end;error(why)end
   return {gain_db=a.gain_db,ceiling_db=a.ceiling_db,true_peak=true,oversampling='2x',next_step='Render measure_mix to verify final loudness and true peak, including the master fader.'}
  elseif name=='configure_eq'then
   local tr,idx,row=own(s,a.track,a.effect);assert(row.plugin:find('ReaEQ',1,true),'This adapter requires ReaEQ')
   local band=({low_shelf=1,bell=2,high_shelf=4})[a.band];assert(band,'Unknown EQ band')
   finite(a.band_index,0,1);assert(a.band_index%1==0,'Integer band index required');finite(a.frequency_hz,20,20000);finite(a.gain_db,-12,12)
   local old={};for i=0,R.TrackFX_GetNumParams(tr,idx)-1 do old[i]=R.TrackFX_GetParamNormalized(tr,idx,i)end
   local good,why=pcall(function()
    assert(R.TrackFX_SetEQParam(tr,idx,band,a.band_index,0,a.frequency_hz,false),'EQ frequency could not be set')
    assert(R.TrackFX_SetEQParam(tr,idx,band,a.band_index,1,10^(a.gain_db/20),false),'EQ gain could not be set')
    local checked=false
    for i=0,R.TrackFX_GetNumParams(tr,idx)-1 do
     local found,bt,bi,pt=R.TrackFX_GetEQParam(tr,idx,i)
     if found and bt==band and bi==a.band_index and pt==1 then
      local _,formatted=R.TrackFX_GetFormattedParamValue(tr,idx,i,'');local v=tonumber(formatted:match('[+-]?[%d%.]+'));assert(v and math.abs(v-a.gain_db)<.11,'EQ gain did not match readback');checked=true
     end
    end
    assert(checked,'EQ band did not exist')
   end)
   if not good then for i,v in pairs(old)do R.TrackFX_SetParamNormalized(tr,idx,i,v)end;error(why)end
   return {band=a.band,frequency_hz=a.frequency_hz,gain_db=a.gain_db}
  elseif name=='set_effect_parameter'then
   local tr,idx=own(s,a.track,a.effect);finite(a.parameter,0,R.TrackFX_GetNumParams(tr,idx)-1);assert(a.parameter%1==0,'Integer parameter index required')
   finite(a.normalized,0,1);local old=R.TrackFX_GetParamNormalized(tr,idx,a.parameter)
   assert(math.abs(old-a.normalized)<=0.200001,'Limit each parameter move to 0.20 normalized units')
   assert(not R.GetFXEnvelope(tr,idx,a.parameter,false),'Automated parameters are protected')
   assert(R.TrackFX_SetParamNormalized(tr,idx,a.parameter,a.normalized),'Parameter was rejected')
   local _,label=R.TrackFX_GetParamName(tr,idx,a.parameter,'');local _,value=R.TrackFX_GetFormattedParamValue(tr,idx,a.parameter,'')
   return {name=label,formatted=value,normalized=R.TrackFX_GetParamNormalized(tr,idx,a.parameter)}
  elseif name=='set_trim_automation'then
   assert(type(a.points)=='table'and #a.points>=2 and #a.points<=256,'Supply 2–256 automation points')
   local previous=-1
   for _,point in ipairs(a.points)do finite(point.seconds,s.bounds[1],s.bounds[2]);finite(point.db,-12,6);assert(point.seconds>previous,'Points must be strictly ordered');previous=point.seconds end
   assert(a.points[1].seconds==s.bounds[1]and a.points[#a.points].seconds==s.bounds[2]and a.points[1].db==0 and a.points[#a.points].db==0,'Use zero dB endpoints at excerpt boundaries')
   local tr=track(a.track,s.project);local idx
   for _,row in ipairs(s.owned)do if row.track==a.track and row.trim then idx=fx_index(tr,row.id)end end
   if not idx then
    assert(#s.owned<24,'Effect limit reached');idx=R.TrackFX_AddByName(tr,'Solo Studio/Mix trim.jsfx',false,-1);assert(idx>=0,'Install Mix trim.jsfx first')
    s.owned[#s.owned+1]={track=a.track,id=R.TrackFX_GetFXGUID(tr,idx),trim=true,plugin='Solo Studio Mix Trim'};journal(s)
   end
   local env=R.GetFXEnvelope(tr,idx,0,true);assert(env,'Could not create trim envelope')
   R.DeleteEnvelopePointRangeEx(env,-1,-math.huge,math.huge)
   -- Native JSFX envelopes use slider units (dB here), not normalized FX values.
   for _,point in ipairs(a.points)do assert(R.InsertEnvelopePointEx(env,-1,point.seconds,point.db,0,0,false,true),'Could not insert envelope point')end
   R.Envelope_SortPointsEx(env,-1);return {points=#a.points}
  else error('Unknown mixing tool')end
 end,debug.traceback)
 R.Undo_EndBlock2(s.project,'Solo Studio mix: '..name,-1);R.UpdateArrange();remember(s)
 if not ok then error(result)end;return result
end
function B.compare(s,mode)
 assert(mode=='original'or mode=='candidate','Choose Original or Candidate')
 B.guard(s,true,true)
 if mode==s.mode then return end
 -- Resolve everything before changing any controls, including when resuming a journal.
 local tracks,effects={},{}
 for _,row in ipairs(s.original)do tracks[row.id]=track(row.id,s.project)end
 for _,row in ipairs(s.owned)do
  local tr=track(row.track,s.project)
  effects[#effects+1]={track=tr,index=fx_index(tr,row.id),row=row}
 end
 if mode=='original'then
  s.candidate={}
  for _,row in ipairs(s.original)do local tr=tracks[row.id];s.candidate[row.id]={volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),pan=R.GetMediaTrackInfo_Value(tr,'D_PAN')}end
  for _,fx in ipairs(effects)do fx.row.candidate_enabled=R.TrackFX_GetEnabled(fx.track,fx.index)end
 end
 local values=mode=='original'and s.original or s.candidate
 for _,row in ipairs(s.original)do
  local v=mode=='original'and row or (values and values[row.id])
  assert(v and type(v.volume)=='number'and type(v.pan)=='number','No candidate snapshot')
 end
 s.render_cache={}
 R.Undo_BeginBlock2(s.project)
 for _,row in ipairs(s.original)do
  local tr=tracks[row.id];local v=mode=='original'and row or values[row.id]
  R.SetMediaTrackInfo_Value(tr,'D_VOL',v.volume);R.SetMediaTrackInfo_Value(tr,'D_PAN',v.pan)
 end
 for _,fx in ipairs(effects)do R.TrackFX_SetEnabled(fx.track,fx.index,mode=='candidate'and fx.row.candidate_enabled~=false)end
 s.mode=mode;R.Undo_EndBlock2(s.project,'Solo Studio compare '..mode,-1);remember(s);R.UpdateArrange()
end
function B.revert(s)
 B.guard(s,false,true);local conflicts=0
 R.Undo_BeginBlock2(s.project)
 for _,row in ipairs(s.original)do
  local ok,tr=pcall(track,row.id,s.project)
  if ok then
   local expected=s.expected[row.id]
   for key,value in pairs({D_VOL=row.volume,D_PAN=row.pan})do
    local prior=expected and (key=='D_VOL'and expected.volume or expected.pan)
    if prior and math.abs(R.GetMediaTrackInfo_Value(tr,key)-prior)<1e-9 then R.SetMediaTrackInfo_Value(tr,key,value)else conflicts=conflicts+1 end
   end
  end
 end
 for _,row in ipairs(s.owned)do
  local ok,tr,idx=pcall(own,s,row.track,row.id);if ok then R.TrackFX_Delete(tr,idx)end
 end
 s.finished=true;journal(s);R.Undo_EndBlock2(s.project,'Solo Studio revert candidate mix',-1);R.UpdateArrange()
 return conflicts
end
function B.keep(s)
 B.guard(s,true,true);assert(s.mode=='candidate','Select Candidate before keeping');s.finished=true;journal(s)
end
function B.archive_current(s)
 -- End the old review without accepting its outdated measurements or touching
 -- any audio settings. Keep its snapshots and analyses on disk for reference.
 B.guard(s,false);assert(not s.finished,'This session is already finished')
 s.finished=true;s.resolution='continued_from_current_mix';journal(s)
end
B.track=track
return B
