-- Native Live import into a new project tab. The source song is never opened for writing.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
local A={}
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function encode(s)
 local out={}
 for i=1,#s,3 do
  local a,b,c=s:byte(i,i+2);local n=(a<<16)|((b or 0)<<8)|(c or 0)
  out[#out+1]=alphabet:sub((n>>18)+1,(n>>18)+1)..alphabet:sub(((n>>12)&63)+1,((n>>12)&63)+1)..(b and alphabet:sub(((n>>6)&63)+1,((n>>6)&63)+1)or '=')..(c and alphabet:sub((n&63)+1,(n&63)+1)or '=')
 end
 return table.concat(out)
end
local function decode(s)
 s=s:gsub('%s','');local lookup={};for i=1,#alphabet do lookup[alphabet:sub(i,i)]=i-1 end
 local out={}
 for i=1,#s,4 do
  local a,b,c,d=s:sub(i,i),s:sub(i+1,i+1),s:sub(i+2,i+2),s:sub(i+3,i+3)
  local n=(assert(lookup[a])<<18)|(assert(lookup[b])<<12)|((lookup[c]or 0)<<6)|(lookup[d]or 0)
  out[#out+1]=string.char((n>>16)&255)..(c~='='and string.char((n>>8)&255)or '')..(d~='='and string.char(n&255)or '')
 end
 return table.concat(out)
end
A.encode,A.decode=encode,decode

local function restore_au(tr,device)
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok,'Could not read AU state')
 local first,last,header,body
 -- The newly appended AU is the last AU node, even in a mixed AU/VST chain.
 for a,h,b,z in chunk:gmatch('()(<AU[^\n]*\n)(.-)\n>()')do first,last,header,body=a,z,h,b end
 assert(first,'AU node missing')
 local typ,sub,man=header:match('(%d+) (%d+) (%d+)%s*$')
 local c=device.plugin.component
 assert(tonumber(typ)==tonumber(c.Type)and tonumber(sub)==tonumber(c.SubType)and tonumber(man)==tonumber(c.Manufacturer),'AU component identity differs from the Live instance')
 local binary=decode(body);local xml=assert(binary:find('<?xml',1,true),'Unsupported REAPER AU state container')
 assert(xml>4,'Invalid AU state prefix')
 local length=string.unpack('<I4',binary,xml-4)
 assert(length>0 and xml+length-1<=#binary and binary:sub(xml,xml+length-1):find('</plist>',1,true),'Invalid AU property-list size')
 local state=read(device.state)
 binary=binary:sub(1,xml-5)..string.pack('<I4',#state)..state..binary:sub(xml+length)
 local b64=encode(binary):gsub(string.rep('.',128),'%0\n')
 local updated=chunk:sub(1,first-1)..header..b64..'\n>'..chunk:sub(last)
 assert(R.SetTrackStateChunk(tr,updated,false),'REAPER rejected AU state')
end

local function parameter_map(tr,fx)
 local out={}
 for p=0,R.TrackFX_GetNumParams(tr,fx)-1 do
  local ok,id=R.TrackFX_GetParamIdent(tr,fx,p)
  if ok then out[id:match(':(%-?%d+)$')or id]=p end
 end
 return out
end

local function envelope(tr,tag)
 local env=R.GetTrackEnvelopeByChunkName(tr,'<'..tag)
 if env then return env end
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok,'Could not read track envelope state')
 local ending=assert(chunk:find('>%s*$'))
 chunk=chunk:sub(1,ending-1)..'<'..tag..'\nACT 1 -1\nVIS 0 1 1\nARM 0\nDEFSHAPE 0 -1 -1\nVOLTYPE 0\n>\n'..chunk:sub(ending)
 assert(R.SetTrackStateChunk(tr,chunk,false),'Could not create track envelope')
 return assert(R.GetTrackEnvelopeByChunkName(tr,'<'..tag),'Envelope not available: '..tag)
end

function A.apply(plan,options)
 options=options or {}
 assert(plan.schema==1 and type(plan.tracks)=='table','Unsupported import plan')
 assert(R.GetPlayState()==0,'Stop playback and recording before importing a Live set.')
 local filename=plan.folder..'/'..plan.name:gsub('[/\\:%c]','_')..'.RPP'
 assert(not R.file_exists(filename),'Import destination already exists; choose a new import folder.')
 local previous=R.EnumProjects(-1,'');local revision=R.GetProjectStateChangeCount(previous)
 local report={plugins=J.array(),warnings=J.array(),tracks=0,clips=0,automation=0,source=plan.source}
 local project;local tracks,fxmap,sendmap,rows={},{},{},{}
 local function warn(message,detail)report.warnings[#report.warnings+1]={message=message,detail=detail}end
 local ok,err=xpcall(function()
  R.Main_OnCommand(41929,0);project=R.EnumProjects(-1,'')
  local master=R.GetMasterTrack(project);R.SetMediaTrackInfo_Value(master,'B_MUTE',1)
  for n=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,n)end
  R.GetSetProjectInfo_String(project,'RECORD_PATH','Media',true)
  R.SetCurrentBPM(project,plan.bpm,false)
  for n=R.CountTempoTimeSigMarkers(project)-1,0,-1 do R.DeleteTempoTimeSigMarker(project,n)end
  local markers={}
  for _,m in ipairs(plan.tempo)do markers[m.time]={time=m.time,bpm=m.bpm}end
  for _,s in ipairs(plan.signatures)do
   local m=markers[s.time]or {time=s.time};m.numerator=s.numerator;m.denominator=s.denominator;markers[s.time]=m
  end
  local ordered={};for _,m in pairs(markers)do ordered[#ordered+1]=m end
  table.sort(ordered,function(a,b)return a.time<b.time end)
  local bpm=plan.bpm
  for _,m in ipairs(ordered)do bpm=m.bpm or bpm;assert(R.SetTempoTimeSigMarker(project,-1,m.time,-1,-1,bpm,m.numerator or 0,m.denominator or 0,false),'Tempo marker failed')end
  local installed={}
  for n=0,10000 do local found,name,ident=R.EnumInstalledFX(n);if not found then break end;installed[#installed+1]={name=name,ident=ident}end
  for _,row in ipairs(plan.tracks)do
   rows[row.id]=row
   local tr
   if row.id=='main'then tr=master else
    R.InsertTrackAtIndex(R.CountTracks(project),false);tr=R.GetTrack(project,R.CountTracks(project)-1);report.tracks=report.tracks+1
    R.GetSetMediaTrackInfo_String(tr,'P_NAME',row.name,true)
   end
   tracks[row.id]=tr;sendmap[row.id]={}
   R.SetMediaTrackInfo_Value(tr,'D_VOL',row.volume);R.SetMediaTrackInfo_Value(tr,'D_PAN',row.pan)
   R.SetMediaTrackInfo_Value(tr,'B_MUTE',row.id=='main'and 1 or row.muted and 1 or 0)
   R.SetMediaTrackInfo_Value(tr,'I_SOLO',row.solo and 1 or 0)
   R.SetMediaTrackInfo_Value(tr,'I_AUTOMODE',0)
   R.SetMediaTrackInfo_Value(tr,'I_RECARM',0);R.SetMediaTrackInfo_Value(tr,'I_RECMON',0)
   R.SetMediaTrackInfo_Value(tr,'D_PANLAW',1) -- Live's stereo balance uses unity center gain.
   R.SetMediaTrackInfo_Value(tr,'B_MAINSEND',0)
   if row.pan_mode~=0 then
    R.SetMediaTrackInfo_Value(tr,'I_PANMODE',6);R.SetMediaTrackInfo_Value(tr,'D_DUALPANL',row.pan_l);R.SetMediaTrackInfo_Value(tr,'D_DUALPANR',row.pan_r)
   end
   if row.delay~=0 then
    R.SetMediaTrackInfo_Value(tr,'I_PLAY_OFFSET_FLAG',row.delay_samples and 2 or 0)
    R.SetMediaTrackInfo_Value(tr,'D_PLAY_OFFSET',row.delay_samples and row.delay or row.delay/1000)
   end
   local mono=row.input:match('AudioIn/External/M(%d+)$');local stereo=row.input:match('AudioIn/External/S(%d+)$')
   R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',mono and tonumber(mono)or stereo and 1024+tonumber(stereo)or -1)
   R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudioAbleton',J.encode({id=row.id,source=plan.source,notes=row.notes}),true)
   for _,d in ipairs(row.devices)do
    local entry={track=row.name,name=d.name,device=d.key,status='unavailable'};report.plugins[#report.plugins+1]=entry
    local fx=-1;local p=d.plugin;local name
    if p then
     for _,candidate in ipairs(installed)do
      local vst3name=candidate.name:match('^VST3i?: (.*)')
      if p.kind=='Vst3PluginInfo'and (candidate.ident:upper():find(p.uid,1,true)or vst3name and (vst3name==p.name or vst3name:sub(1,#p.name+2)==p.name..' ('))then name=candidate.name;break end
      if p.kind=='AuPluginInfo'and candidate.ident==p.manufacturer..': '..p.name then name=candidate.name;break end
     end
     if name then fx=R.TrackFX_AddByName(tr,name,false,-1)end
    elseif d.type=='Tuner'then fx=R.TrackFX_AddByName(tr,'ReaTune (Cockos)',false,-1)end
    if fx>=0 then
     local loaded,problem=pcall(function()
      if p then
       assert(d.state,'Saved plugin state is unavailable')
       if p.kind=='AuPluginInfo'then restore_au(tr,d)
       elseif p.kind=='Vst3PluginInfo'then
        local _,ident=R.TrackFX_GetNamedConfigParm(tr,fx,'fx_ident');assert(ident:upper():find(p.uid,1,true),'VST3 identity mismatch')
        assert(R.TrackFX_SetPreset(tr,fx,d.state),'VST3 state restore failed')
       else error('No verified state loader for this plugin format')end
      end
     end)
     if loaded then
      entry.status=p and 'state restored'or 'tuner substituted';entry.fx=fx
      local params=parameter_map(tr,fx);fxmap[d.key]={track=tr,index=fx,parameters=params}
      -- Saved state is authoritative. Compare exposed parameters without overwriting
      -- internal vendor state with stale host values.
      entry.parameters_checked=0;entry.parameter_differences=J.array()
      for _,param in ipairs(d.parameters or {})do
       local idx=params[param.id]
       if idx then
        entry.parameters_checked=entry.parameters_checked+1
        local actual=R.TrackFX_GetParamNormalized(tr,fx,idx)
        if math.abs(actual-param.value)>0.002 then entry.parameter_differences[#entry.parameter_differences+1]={id=param.id,expected=param.value,actual=actual}end
       end
      end
      if #entry.parameter_differences>0 then warn('Saved plug-in state loaded, but some exposed parameter values differ from Live.',row.name..': '..d.name)end
      R.TrackFX_SetEnabled(tr,fx,d.enabled)
     else
      R.TrackFX_Delete(tr,fx);fx=-1;entry.error=tostring(problem)
     end
    end
    if fx<0 then
     warn('Device needs review: '..d.name,entry.error or 'No verified native counterpart/installed identity.')
     -- Visible placeholder keeps chain position and makes an omitted processor
     -- apparent in the mixer. The complete device XML/state remains archived.
     local placeholder=R.TrackFX_AddByName(tr,'JS: Volume Adjustment',false,-1)
     if placeholder>=0 then R.TrackFX_SetNamedConfigParm(tr,placeholder,'renamed_name','UNIMPORTED Live: '..d.name);R.TrackFX_SetEnabled(tr,placeholder,false)end
    end
   end
  end
  -- Folder depths follow original contiguous parent order. Explicit sends retain
  -- the routing independently of the visual nesting, avoiding duplicate paths.
  local order={};for _,r in ipairs(plan.tracks)do if r.id~='main'then order[#order+1]=r end end
  local function ancestry(row)
   local depth=0;local seen={}
   while row and row.group~='-1'do assert(not seen[row.group],'Cyclic Live group routing');seen[row.group]=true;depth=depth+1;row=rows[row.group]end
   return depth
  end
  for i,row in ipairs(order)do
   local delta=(order[i+1]and ancestry(order[i+1])or 0)-ancestry(row)
   R.SetMediaTrackInfo_Value(tracks[row.id],'I_FOLDERDEPTH',delta)
  end
  local function send(source,destination,gain,mode,midi)
   local index=assert(R.CreateTrackSend(source,destination));assert(index>=0,'Could not create send')
   R.SetTrackSendInfo_Value(source,0,index,'D_VOL',gain);R.SetTrackSendInfo_Value(source,0,index,'I_SENDMODE',mode)
   R.SetTrackSendInfo_Value(source,0,index,'I_MIDIFLAGS',midi and 0 or 31)
   return index
  end
  local function hardware(tr,row)
   local stereo=row.output:match('^AudioOut/External/S(%d+)$')
   local mono=row.output:match('^AudioOut/External/M(%d+)$')
   if not stereo and not mono then return false end
   if options.silent then return true end
   local channel=stereo and tonumber(stereo)*2 or tonumber(mono)
   if channel+(stereo and 2 or 1)>R.GetNumAudioOutputs()then
    warn('External output is unavailable on the current audio device.',row.name..': '..(row.output_label or row.output));return true
   end
   local index=R.CreateTrackSend(tr,nil);assert(index>=0,'Hardware send failed')
   R.SetTrackSendInfo_Value(tr,1,index,'I_DSTCHAN',channel+(mono and 1024 or 0))
   R.SetTrackSendInfo_Value(tr,1,index,'D_VOL',1)
   return true
  end
  for _,row in ipairs(order)do
   local tr=tracks[row.id];local output=row.output
   local destination=output=='AudioOut/GroupTrack'and tracks[row.group]or (output=='AudioOut/Master'or output=='AudioOut/Main')and master
   if not destination then
    local id=output:match('AudioOut/Track%.(%d+)')or output:match('AudioOut/Track/(%d+)')
    destination=id and tracks[id]
   end
   if destination and destination~=master then send(tr,destination,1,0,false)
   elseif destination==master then
    -- B_MAINSEND would feed the containing folder; use explicit send to main
    -- only for nested tracks that intentionally bypass their group.
    if row.group=='-1'then R.SetMediaTrackInfo_Value(tr,'B_MAINSEND',1)else send(tr,master,1,0,false)end
   elseif hardware(tr,row)then
   elseif output~=''and output~='AudioOut/None'then warn('Unmapped output is disconnected: '..output,row.name)end
   for _,s in ipairs(row.sends)do
    local dest=tracks[s.destination]
    if dest then
     local idx=send(tr,dest,s.gain,s.pre and 3 or 0,false)
     R.SetTrackSendInfo_Value(tr,0,idx,'B_MUTE',s.enabled and 0 or 1)
     sendmap[row.id][s.id]={index=idx,destination=dest,receive=R.GetTrackNumSends(dest,-1)-1}
    else warn('Return send destination not found.',row.name..' send '..s.id)end
   end
   if row.midi_output~=''and row.midi_output~='MidiOut/None'then warn('External/track MIDI output needs manual routing.',row.name..': '..row.midi_output)end
  end
  for _,row in ipairs(order)do
   local tr=tracks[row.id];local comp={}
   if row.type=='AudioTrack'or row.type=='MidiTrack'then
    R.SetMediaTrackInfo_Value(tr,'I_FREEMODE',2);R.SetMediaTrackInfo_Value(tr,'C_LANESETTINGS',30)
    R.SetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES',#row.lanes)
   end
   for _,c in ipairs(row.clips)do
    local item,take
    if c.kind=='midi'then
     item=R.CreateNewMIDIItemInProj(tr,c.position,c.position+c.length,false);take=R.GetActiveTake(item)
     for _,n in ipairs(c.notes_midi)do
      assert(R.MIDI_InsertNote(take,false,n.muted,R.MIDI_GetPPQPosFromProjTime(take,n.start),R.MIDI_GetPPQPosFromProjTime(take,n['end']),0,n.pitch,math.max(1,math.min(127,n.velocity)),true),'MIDI note failed')
     end
     for _,cc in ipairs(c.cc)do
      local time=R.MIDI_GetPPQPosFromProjTime(take,cc.time);local v=math.floor(cc.value+0.5)
      if cc.controller==0 then v=math.max(0,math.min(16383,v+8192));R.MIDI_InsertCC(take,false,false,time,0xE0,0,v&127,v>>7)
      elseif cc.controller==1 then R.MIDI_InsertCC(take,false,false,time,0xD0,0,math.max(0,math.min(127,v)),0)
      elseif cc.controller>=2 and cc.controller<130 then R.MIDI_InsertCC(take,false,false,time,0xB0,0,cc.controller-2,math.max(0,math.min(127,v)))end
     end
     R.MIDI_Sort(take)
    else
     item=R.AddMediaItemToTrack(tr);take=R.AddTakeToMediaItem(item)
     if c.media~=''then
      local source=R.PCM_Source_CreateFromFile(c.media)
      if source then R.SetMediaItemTake_Source(take,source)else warn('REAPER could not open media.',c.media)end
     end
     R.SetMediaItemTakeInfo_Value(take,'D_STARTOFFS',c.offset)
     R.SetMediaItemTakeInfo_Value(take,'D_PITCH',c.warped and c.pitch or 0)
     R.SetMediaItemTakeInfo_Value(take,'D_PLAYRATE',c.warped and 1 or 2^(c.pitch/12))
     R.SetMediaItemTakeInfo_Value(take,'B_PPITCH',c.warped and c.warp_mode~='3'and 1 or 0)
     for _,m in ipairs(c.stretch)do assert(R.SetTakeStretchMarker(take,-1,m[1],m[2])>=0,'Stretch marker rejected')end
     R.SetMediaItemInfo_Value(item,'D_FADEINLEN',math.min(c.length,c.fade_in));R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',math.min(c.length,c.fade_out))
     R.SetMediaItemInfo_Value(item,'D_FADEINLEN_AUTO',-1);R.SetMediaItemInfo_Value(item,'D_FADEOUTLEN_AUTO',-1)
    end
    R.SetMediaItemInfo_Value(item,'D_POSITION',c.position);R.SetMediaItemInfo_Value(item,'D_LENGTH',c.length)
    R.SetMediaItemInfo_Value(item,'D_VOL',c.gain);R.SetMediaItemInfo_Value(item,'B_MUTE',c.muted and 1 or 0)
    R.SetMediaItemInfo_Value(item,'B_LOOPSRC',0);R.SetMediaItemInfo_Value(item,'I_FIXEDLANE',c.lane)
    R.SetMediaItemInfo_Value(item,'C_BEATATTACHMODE',c.kind=='audio'and not c.warped and 2 or 1)
    local name=(c.media_status and c.media_status~='found'and '[MISSING AUDIO] 'or '')..c.name
    R.GetSetMediaItemTakeInfo_String(take,'P_NAME',name,true)
    R.GetSetMediaItemInfo_String(item,'P_NOTES',c.notes..(c.original_media and '\nLive source: '..c.original_media or ''),true)
    R.GetSetMediaItemInfo_String(item,'P_EXT:SoloStudioAbleton',J.encode({clip=c.source_id,take=c.take_id,context=c.context}),true)
    -- Historical takes may have been recorded at another BPM; do not falsely
    -- label them with the current song tempo.
    if c.lane==0 then local _,guid=R.GetSetMediaItemInfo_String(item,'GUID','',false);comp[#comp+1]=guid end
    report.clips=report.clips+1
   end
   for n,name in ipairs(row.lanes)do R.GetSetMediaTrackInfo_String(tr,'P_LANENAME:'..(n-1),name,true)end
   R.GetSetMediaTrackInfo_String(tr,'P_EXT:SoloStudioComp',table.concat(comp,'\n'),true)
   R.SetMediaTrackInfo_Value(tr,'C_LANEPLAYS:0',1);R.SetMediaTrackInfo_Value(tr,'C_LANESCOLLAPSED',1)
  end
  local tags={volume='VOLENV2',pan='PANENV2',mute='MUTEENV',pan_l='DUALPANENVL',pan_r='DUALPANENVR'}
  for _,automation in ipairs(plan.automation)do
   local success,problem=pcall(function()
    local tr=assert(tracks[automation.track]);local kind=automation.kind;local envs={}
    if tags[kind]then envs[1]=envelope(tr,tags[kind])
    elseif kind=='parameter'or kind=='bypass'then
     local fx=assert(fxmap[automation.device],'Plugin unavailable')
     local param=kind=='bypass'and R.TrackFX_GetParamFromIdent(tr,fx.index,':bypass')or fx.parameters[automation.parameter]
     assert(param and param>=0,'Plugin parameter ID unavailable')
     envs[1]=assert(R.GetFXEnvelope(tr,fx.index,param,true))
    elseif kind=='rack-bypass'then
     for _,id in ipairs(automation.devices)do local fx=assert(fxmap[id]);local param=R.TrackFX_GetParamFromIdent(tr,fx.index,':bypass');envs[#envs+1]=assert(R.GetFXEnvelope(tr,fx.index,param,true))end
    elseif kind=='send'then
     local s=assert(sendmap[automation.track][automation.send],'Send unavailable')
     -- Send envelopes are serialized on the receive track in REAPER.
     local ok,chunk=R.GetTrackStateChunk(s.destination,'',false);assert(ok)
     local lines={'<AUXVOLENV','ACT 1 -1','VIS 0 1 1','ARM 0','DEFSHAPE 0 -1 -1','VOLTYPE 0'}
     for _,p in ipairs(automation.points)do lines[#lines+1]=string.format('PT %.17g %.17g %d',p.time,p.value,p.step and 1 or 0)end
     lines[#lines+1]='>'
     local receive=-1;local inserted=false
     chunk=chunk:gsub('(AUXRECV[^\n]*\n)',function(line)
      receive=receive+1;if receive==s.receive then inserted=true;return line..table.concat(lines,'\n')..'\n'end;return line
     end)
     assert(inserted and R.SetTrackStateChunk(s.destination,chunk,false),'Send envelope was not attached')
     R.SetTrackSendInfo_Value(tr,0,s.index,'I_AUTOMODE',1)
     R.SetTrackSendInfo_Value(tr,0,s.index,'D_VOL',1)
    else error('Unsupported envelope kind')end
    for _,env in ipairs(envs)do
     R.DeleteEnvelopePointRange(env,-1e10,1e10)
     for _,p in ipairs(automation.points)do
      local v=p.value*(automation.scale or 1)
      if kind=='mute'or kind=='bypass'or kind=='rack-bypass'then v=1-v end
      assert(R.InsertEnvelopePoint(env,p.time,R.ScaleToEnvelopeMode(R.GetEnvelopeScalingMode(env),v),p.step and 1 or 0,0,false,true),'Envelope point failed')
     end
     R.Envelope_SortPoints(env)
    end
    if kind=='volume'then R.SetMediaTrackInfo_Value(tr,'D_VOL',1)end
    if kind=='pan'then R.SetMediaTrackInfo_Value(tr,'D_PAN',0)end
    R.SetMediaTrackInfo_Value(tr,'I_AUTOMODE',1)
   end)
   if success then report.automation=report.automation+1 else warn('Automation could not be applied.',tostring(problem))end
  end
  local finish=0;for _,row in ipairs(order)do for _,c in ipairs(row.clips)do if c.context=='arrangement'then finish=math.max(finish,c.position+c.length)end end end
  for n,l in ipairs(plan.locators)do
   local ending=plan.locators[n+1]and plan.locators[n+1].time or finish
   R.AddProjectMarker2(project,ending>l.time,l.time,math.max(l.time,ending),l.name,-1,0)
  end
  -- Register original linked recording groups, then individual instruments. Lane
  -- counts can differ in old sets; preserve them rather than invent synchronization.
  local sets,linked={},{}
  for _,row in ipairs(order)do if row.type=='AudioTrack'or row.type=='MidiTrack'then
   local key=row.linked_group~='-1'and 'linked-'..row.linked_group or 'track-'..row.id
   if not linked[key]then linked[key]={name=row.name,tracks={},rows={}};sets[#sets+1]=key end
   linked[key].tracks[#linked[key].tracks+1]=R.GetTrackGUID(tracks[row.id]);linked[key].rows[#linked[key].rows+1]=row
  end end
  for group_index,id in ipairs(sets)do
   local set=linked[id];local name=#set.tracks>1 and ('Linked '..set.name)or set.name
   if #set.tracks>1 then
    local ancestor=set.rows[1].group
    while rows[ancestor]do
     local common=true
     for _,row in ipairs(set.rows)do
      local parent=row.group;local found=false
      while rows[parent]do if parent==ancestor then found=true;break end;parent=rows[parent].group end
      if not found then common=false;break end
     end
     if common then name=rows[ancestor].name;break end
     ancestor=rows[ancestor].group
    end
    if group_index<=64 then
     local membership=group_index<=32 and R.GetSetTrackGroupMembership or R.GetSetTrackGroupMembershipHigh
     local mask=1<<((group_index-1)%32)
     for _,row in ipairs(set.rows)do for _,role in ipairs({'MEDIA_EDIT_LEAD','MEDIA_EDIT_FOLLOW'})do membership(tracks[row.id],role,mask,mask)end end
    end
   end
   R.SetProjExtState(project,'SoloStudio_v1','set.'..id..'.name',name)
   R.SetProjExtState(project,'SoloStudio_v1','set.'..id..'.tracks',table.concat(set.tracks,'\n'))
  end
  R.SetProjExtState(project,'SoloStudio_v1','sets',table.concat(sets,'\n'))
  R.SetProjExtState(project,'SoloStudio_v1','active',sets[1]or '')
  R.SetProjExtState(project,'SoloStudio_v1','ableton.source',plan.source)
  R.SetProjExtState(project,'SoloStudio_v1','ableton.report',plan.folder..'/Import report.md')
  R.SetEditCurPos2(project,0,false,false)
  R.UpdateTimeline();R.TrackList_AdjustWindows(false)
  if not hardware(master,rows.main)and not options.silent then
   local out=R.CreateTrackSend(master,nil);if out>=0 then R.SetTrackSendInfo_Value(master,1,out,'I_DSTCHAN',0)end
  end
  R.SetMediaTrackInfo_Value(master,'B_MUTE',rows.main.muted and 1 or 0)
  R.Main_SaveProjectEx(project,filename,8);assert(R.file_exists(filename),'REAPER could not save the imported project')
  report.project=filename;report.ok=true
 end,debug.traceback)
 report.ok=ok;report.error=err;report.original_unchanged=R.GetProjectStateChangeCount(previous)==revision
 J.write(plan.folder..'/native-report.json',report)
 local report_path=plan.folder..'/Import report.md'
 local f=io.open(report_path,'rb');local body=f and f:read('*a')or '# Ableton import\n';if f then f:close()end
 local cut=body:find('\n## REAPER import results',1,true);if cut then body=body:sub(1,cut-1)end
 local lines={body,'','## REAPER import results','',ok and 'The imported project was saved successfully.'or 'Import stopped: '..tostring(err),
  string.format('%d tracks / %d clips / %d automation envelopes applied.',report.tracks,report.clips,report.automation),
  'Original project revision unchanged: '..tostring(report.original_unchanged)..'.','','| Track | Plug-in | Result | Parameter checks |','| --- | --- | --- | ---: |'}
 local function cell(s)return tostring(s or ''):gsub('[\r\n|]',' ')end
 for _,p in ipairs(report.plugins)do lines[#lines+1]='| '..cell(p.track)..' | '..cell(p.name)..' | '..cell(p.status)..' | '..(p.parameters_checked or 0)..' |'end
 lines[#lines+1]='';lines[#lines+1]='### Native review items';lines[#lines+1]=''
 for _,w in ipairs(report.warnings)do lines[#lines+1]='- '..cell(w.message)..' '..cell(w.detail)end
 f=assert(io.open(report_path,'wb'));f:write(table.concat(lines,'\n')..'\n');f:close()
 if not ok then
  if project then R.SetMediaTrackInfo_Value(R.GetMasterTrack(project),'B_MUTE',1)end
  R.SelectProjectInstance(previous)
  error('Import stopped; source project preserved. Review '..plan.folder..'/native-report.json\n'..tostring(err),0)
 end
 return project,report
end

function A.start(source,root,media_root)
 local worker=dir..'/Ableton/prepare.py';if not R.file_exists(worker)then worker=dir..'/../Ableton/prepare.py'end
 assert(R.file_exists(worker),'Ableton import helper is not installed.')
 R.RecursiveCreateDirectory(root,0)
 local name=(source:match('([^/]+)%.als$')or 'Live import'):gsub('[/\\:%c]','_')
 local folder=root..'/'..name..' - Live import '..os.date('%Y-%m-%d %H%M%S')
 if R.file_exists(folder..'/import-plan.json')then folder=folder..'-'..R.genGuid():sub(2,9)end
 local status=root..'/.ableton-'..R.genGuid():sub(2,9)..'.json'
 local command='/usr/bin/python3 '..quote(worker)..' '..quote(source)..' --output '..quote(folder)..' --status '..quote(status)
 if media_root and media_root~=''then command=command..' --media-root '..quote(media_root)end
 assert(R.ExecProcess(command,-1),'Could not start Ableton import analysis')
 return {status=status,folder=folder,source=source}
end
function A.poll(job)return J.read(job.status)end
function A.read_plan(path)return assert(J.read(path),'Import plan is missing')end
function A.reveal(folder)R.ExecProcess('/usr/bin/open '..quote(folder),-1)end
return A
