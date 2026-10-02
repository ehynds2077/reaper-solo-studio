-- Restorable master gain, FX order, sends, pre-FX rides and named experiments.
local R=reaper;local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local State=dofile(dir..'/solo_mix_state.lua');local F=dofile(dir..'/solo_mix_effects.lua');local J=dofile(dir..'/solo_json.lua')
local E={}
local fields={'D_VOL','D_PAN','B_MUTE','I_SENDMODE','I_SRCCHAN','I_DSTCHAN','I_MIDIFLAGS'}
local function controls(s)s.controls=s.controls or {orders={},sends=J.array(),checkpoints=J.array()};return s.controls end
local function order(tr)local ids=J.array();for i=0,R.TrackFX_GetCount(tr)-1 do ids[#ids+1]=R.TrackFX_GetFXGUID(tr,i)end;return ids end
local function same(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not same(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function send_values(tr,index)local v={};for _,key in ipairs(fields)do v[key]=R.GetTrackSendInfo_Value(tr,0,index,key)end;return v end
local function send_index(s,row,A)
 local tr=A.track(row.track,s.project);local dest=A.track(row.destination,s.project)
 assert(R.GetTrackSendInfo_Value(tr,0,row.index,'P_DESTTRACK')==dest,'Send changed; inspect routing again')
 return tr,row.index
end
local function send_write(tr,index,values)
 for _,key in ipairs(fields)do if values[key]~=nil then
  R.SetTrackSendInfo_Value(tr,0,index,key,values[key])
  assert(math.abs(R.GetTrackSendInfo_Value(tr,0,index,key)-values[key])<1e-8,'Send setting did not match readback')
 end end
end
local function reorder(tr,ids,A)
 for i,id in ipairs(ids)do
  local index=A.fx_index(tr,id)
  if index~=i-1 then R.TrackFX_CopyToTrack(tr,index,tr,i-1,true)end
  assert(R.TrackFX_GetFXGUID(tr,i-1)==id,'Effect order could not be restored')
 end
end
function E.remember(s,A)
 local c=s.controls;if not c then return end
 if c.master then c.master.expected=R.GetMediaTrackInfo_Value(R.GetMasterTrack(s.project),'D_VOL');if s.mode=='candidate'then c.master.candidate=c.master.expected end end
 for guid,row in pairs(c.orders)do row.expected=order(A.track(guid,s.project));if s.mode=='candidate'then row.candidate=row.expected end end
 for _,row in ipairs(c.sends)do local tr,i=send_index(s,row,A);row.expected=send_values(tr,i);if s.mode=='candidate'then row.candidate=row.expected end end
 for _,row in ipairs(c.buses or {})do local ok,chunk=R.GetTrackStateChunk(A.track(row.id,s.project),'',false);assert(ok);row.expected=State.normalize(chunk)end
end
function E.order_checkpoint(s,guid,A)
 local c=controls(s)
 if not c.orders[guid]then local ids=order(A.track(guid,s.project));c.orders[guid]={original=ids,expected=ids,candidate=ids};A.journal(s)end
end
function E.guard(s,A)
 local c=s.controls;if not c then return end
 if c.master then assert(math.abs(R.GetMediaTrackInfo_Value(R.GetMasterTrack(s.project),'D_VOL')-c.master.expected)<1e-9,'Master output changed outside the mixer')end
 for guid,row in pairs(c.orders)do assert(same(order(A.track(guid,s.project)),row.expected),'Effect order changed outside the mixer')end
 for _,row in ipairs(c.sends)do local tr,i=send_index(s,row,A);assert(same(send_values(tr,i),row.expected),'Send changed outside the mixer')end
end
function E.compare(s,mode,A)
 local c=s.controls;if not c then return end
 E.guard(s,A)
 if c.master then R.SetMediaTrackInfo_Value(R.GetMasterTrack(s.project),'D_VOL',c.master[mode])end
 for guid,row in pairs(c.orders)do reorder(A.track(guid,s.project),row[mode],A)end
 for _,row in ipairs(c.sends)do
  local tr,i=send_index(s,row,A);local v=row[mode]
  if not v then v=send_values(tr,i);v.B_MUTE=1 end
  send_write(tr,i,v)
 end
end
function E.revert(s,A)
 local c=s.controls;if not c then return 0 end;local conflicts=0
 if c.master then
  local tr=R.GetMasterTrack(s.project)
  if math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-c.master.expected)<1e-9 then R.SetMediaTrackInfo_Value(tr,'D_VOL',c.master.original)else conflicts=conflicts+1 end
 end
 for guid,row in pairs(c.orders)do
  local ok=pcall(function()local tr=A.track(guid,s.project);assert(same(order(tr),row.expected));reorder(tr,row.original,A)end)
  if not ok then conflicts=conflicts+1 end
 end
 -- Reverse index order keeps any remaining send identifiers stable.
 local sends={};for _,row in ipairs(c.sends)do sends[#sends+1]=row end
 table.sort(sends,function(a,b)if a.track==b.track then return a.index>b.index end;return a.track>b.track end)
 for _,row in ipairs(sends)do
  local ok=pcall(function()
   local tr,i=send_index(s,row,A);assert(same(send_values(tr,i),row.expected))
   if row.original then send_write(tr,i,row.original)else assert(R.RemoveTrackSend(tr,0,i),'Could not remove added send')end
  end)
  if not ok then conflicts=conflicts+1 end
 end
 return conflicts
end
local function capture(s,A)
 local out={tracks={},sends={}}
 for i=-1,R.CountTracks(s.project)-1 do
  local tr=i==-1 and R.GetMasterTrack(s.project)or R.GetTrack(s.project,i)
  local id=i==-1 and 'MASTER'or R.GetTrackGUID(tr);local row={volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),pan=R.GetMediaTrackInfo_Value(tr,'D_PAN'),fx={},order=order(tr)}
  for _,fx in ipairs(row.order)do row.fx[fx]=F.capture(tr,fx)end
  out.tracks[id]=row
 end
 for _,row in ipairs(controls(s).sends)do local tr,i=send_index(s,row,A);out.sends[row.track..':'..row.index]=send_values(tr,i)end
 return out
end
local function restore(s,snapshot,A)
 local plans={};local desired={}
 for _,row in ipairs(controls(s).buses or {})do if not snapshot.tracks[row.id]then snapshot.tracks[row.id]={volume=0,pan=0,fx={},order={}}end end
 for id,row in pairs(snapshot.tracks)do
  local tr=A.track(id,s.project);local replacements={}
  for fx,value in pairs(row.fx)do A.fx_index(tr,fx);replacements[fx]=value end
  -- Effects added after a checkpoint stay available, bypassed, for later trials.
  for _,owned in ipairs(s.owned)do if owned.track==id and not row.fx[owned.id]then
   local value=F.capture(tr,owned.id)
   replacements[owned.id]=value:gsub('^(%s*BYPASS%s+)[01]',function(prefix)return prefix..'1'end,1)
  end end
  if next(replacements)then plans[#plans+1]=F.plan(tr,replacements)end
  desired[#desired+1]={track=tr,row=row}
 end
 F.apply(plans)
 for _,v in ipairs(desired)do
  reorder(v.track,v.row.order,A)
  R.SetMediaTrackInfo_Value(v.track,'D_VOL',v.row.volume);R.SetMediaTrackInfo_Value(v.track,'D_PAN',v.row.pan)
 end
 for _,row in ipairs(controls(s).sends)do
  local tr,i=send_index(s,row,A);local v=snapshot.sends[row.track..':'..row.index]
  if not v then v=row.original or send_values(tr,i);if not row.original then v.B_MUTE=1 end end
  send_write(tr,i,v)
 end
end
local function no_feedback(s,source,destination,A)
 local seen={}
 local function visit(tr)
  if tr==source then return true end
  if seen[tr]then return false end;seen[tr]=true
  local parent=R.GetParentTrack(tr)
  if parent and R.GetMediaTrackInfo_Value(tr,'B_MAINSEND')~=0 and visit(parent)then return true end
  for i=0,R.GetTrackNumSends(tr,0)-1 do local dest=R.GetTrackSendInfo_Value(tr,0,i,'P_DESTTRACK');if dest and visit(dest)then return true end end
  return false
 end
 assert(not visit(destination),'Send would create a feedback loop, including folder routing')
end
function E.execute(s,name,a,A)
 local c=controls(s)
 if name=='create_mix_bus'then
  assert(type(a.name)=='string'and #a.name>0 and #a.name<=80 and not a.name:find('%c'),'Use a single-line bus name up to 80 characters')
  c.buses=c.buses or J.array();assert(#c.buses<8,'Session bus limit reached')
  R.InsertTrackAtIndex(R.CountTracks(s.project),false);local tr=R.GetTrack(s.project,R.CountTracks(s.project)-1)
  if R.GetParentTrack(tr)then R.DeleteTrack(tr);error('Last folder is open; create an outside-folder bus in REAPER first')end
  R.GetSetMediaTrackInfo_String(tr,'P_NAME',a.name,true);R.SetMediaTrackInfo_Value(tr,'I_RECARM',0);R.SetMediaTrackInfo_Value(tr,'I_RECINPUT',-1)
  for i=R.GetTrackNumSends(tr,1)-1,0,-1 do R.RemoveTrackSend(tr,1,i)end
  local id=R.GetTrackGUID(tr);c.buses[#c.buses+1]={id=id,name=a.name}
  s.original[#s.original+1]={id=id,volume=0,pan=0,added=true};s.expected[id]={volume=R.GetMediaTrackInfo_Value(tr,'D_VOL'),pan=0};A.journal(s)
  return {track=id,name=a.name,next_step='Add a fully wet reverb/delay, then use set_send from source tracks. No recording input or hardware output was added.'}
 elseif name=='set_master_output'then
  A.finite(a.volume_db,-60,12);local tr=R.GetMasterTrack(s.project)
  assert(not A.active_envelope(tr,'<VOLENV2'),'Master volume is automated; preserve its envelope')
  if not c.master then local gain=R.GetMediaTrackInfo_Value(tr,'D_VOL');c.master={original=gain,candidate=gain,expected=gain};A.journal(s)end
  local gain=10^(a.volume_db/20);R.SetMediaTrackInfo_Value(tr,'D_VOL',gain)
  assert(math.abs(R.GetMediaTrackInfo_Value(tr,'D_VOL')-gain)<1e-9,'Master output readback failed')
  return {volume_db=a.volume_db,next_step='This gain is after master FX. Re-measure full output loudness and true peak before accepting.'}
 elseif name=='move_effect'then
  local tr=A.track(a.track,s.project);local index=A.fx_index(tr,a.effect)
  A.finite(a.index,0,R.TrackFX_GetCount(tr)-1);assert(a.index%1==0,'Integer chain index required')
  E.order_checkpoint(s,a.track,A);R.TrackFX_CopyToTrack(tr,index,tr,a.index,true)
  assert(R.TrackFX_GetFXGUID(tr,a.index)==a.effect,'Effect move failed')
  return {effect=a.effect,index=a.index}
 elseif name=='set_send'then
  assert(a.track~='MASTER'and a.destination~='MASTER','Use sends between ordinary tracks; master output has a separate control')
  local tr=A.track(a.track,s.project);local dest=A.track(a.destination,s.project);no_feedback(s,tr,dest,A)
  A.finite(a.volume_db,-90,6);if a.pan~=nil then A.finite(a.pan,-1,1)end
  if a.muted~=nil then assert(type(a.muted)=='boolean','muted must be boolean')end
  local send_mode=a.mode and assert(({post_fader=0,pre_fx=1,post_fx=3})[a.mode],'Unknown send position')
  local index=a.index
  if index~=nil then A.finite(index,0,R.GetTrackNumSends(tr,0)-1);assert(index%1==0 and R.GetTrackSendInfo_Value(tr,0,index,'P_DESTTRACK')==dest,'Send index/destination mismatch')
  else for i=0,R.GetTrackNumSends(tr,0)-1 do if R.GetTrackSendInfo_Value(tr,0,i,'P_DESTTRACK')==dest then assert(index==nil,'Multiple sends exist: specify the exact index');index=i end end end
  local created=index==nil
  if not created then
   for _,key in ipairs({'P_ENV:<VOLENV','P_ENV:<PANENV','P_ENV:<MUTEENV'})do
    local env=R.GetTrackSendInfo_Value(tr,0,index,key)
    if env and env~=0 then local ok,chunk=R.GetEnvelopeStateChunk(env,'',false);assert(ok and not chunk:match('\n%s*ACT%s+1'),'This send is automated; preserve its envelope')end
   end
  end
  local row
  for _,v in ipairs(c.sends)do if v.track==a.track and v.index==index then row=v end end
  if created then index=R.CreateTrackSend(tr,dest);assert(index>=0,'Could not create send')end
  if not row then local initial=send_values(tr,index);row={track=a.track,destination=a.destination,index=index,original=not created and initial or nil,expected=initial,candidate=initial};c.sends[#c.sends+1]=row;A.journal(s)end
  local values=send_values(tr,index);values.D_VOL=10^(a.volume_db/20)
  if created then values.I_SRCCHAN=0;values.I_DSTCHAN=0;values.I_MIDIFLAGS=31;values.I_SENDMODE=0 end
  if a.pan~=nil then values.D_PAN=a.pan end;if a.muted~=nil then values.B_MUTE=a.muted and 1 or 0 end
  if send_mode then values.I_SENDMODE=send_mode end
  local before=send_values(tr,index);local ok,err=pcall(send_write,tr,index,values)
  if not ok then
   if created then
    R.RemoveTrackSend(tr,0,index)
    for n,v in ipairs(c.sends)do if v==row then table.remove(c.sends,n);break end end
   else send_write(tr,index,before)end
   error(err)
  end
  return {index=index,destination=a.destination,volume_db=a.volume_db,muted=values.B_MUTE~=0,mode=values.I_SENDMODE}
 elseif name=='save_mix_checkpoint'then
  assert(type(a.name)=='string'and #a.name>0 and #a.name<=80,'Name must be 1–80 characters')
  assert(#c.checkpoints<24,'Checkpoint limit reached; delete an unused checkpoint')
  local id=R.genGuid():gsub('[^%w]','');local snapshot=capture(s,A)
  J.write(s.path..'/checkpoint-'..id..'.json',snapshot)
  local row={id=id,name=a.name};c.checkpoints[#c.checkpoints+1]=row;A.journal(s);return row
 elseif name=='list_mix_checkpoints'then return {checkpoints=c.checkpoints}
 elseif name=='restore_mix_checkpoint'or name=='delete_mix_checkpoint'then
  local found;for i,row in ipairs(c.checkpoints)do if row.id==a.id then found=i end end;assert(found,'Unknown checkpoint')
  local path=s.path..'/checkpoint-'..c.checkpoints[found].id..'.json'
  if name=='delete_mix_checkpoint'then os.remove(path);table.remove(c.checkpoints,found);A.journal(s);return {deleted=true}end
  local snapshot=assert(J.read(path),'Checkpoint file is missing');local before=capture(s,A)
  -- Any existing plugin restored by an experiment must also be revertible to
  -- the original session. Capture originals BEFORE the first restoration.
  for id,row in pairs(snapshot.tracks)do
   E.order_checkpoint(s,id,A)
   for fx in pairs(row.fx)do A.editable(s,id,fx)end
  end
  if not c.master then local gain=R.GetMediaTrackInfo_Value(R.GetMasterTrack(s.project),'D_VOL');c.master={original=gain,candidate=gain,expected=gain};A.journal(s)end
  local ok,err=pcall(restore,s,snapshot,A)
  if not ok then local restored,why=pcall(restore,s,before,A);assert(restored,tostring(err)..'; checkpoint rollback failed: '..tostring(why));error(err)end
  return {restored=a.id,name=c.checkpoints[found].name,next_step='All previous analysis is stale. Inspect the current chain, then measure this checkpoint.'}
 end
 error('Unknown extended mixing tool')
end
E.names={create_mix_bus=true,set_master_output=true,move_effect=true,set_send=true,save_mix_checkpoint=true,list_mix_checkpoints=true,restore_mix_checkpoint=true,delete_mix_checkpoint=true}
function E.removable_buses(s,A)
 local ids={};local conflicts=0
 for _,row in ipairs(s.controls and s.controls.buses or {})do
  local ok,tr=pcall(A.track,row.id,s.project)
  if ok then local good,chunk=R.GetTrackStateChunk(tr,'',false)
   if good and R.CountTrackMediaItems(tr)==0 and State.normalize(chunk)==row.expected then ids[#ids+1]=row.id else conflicts=conflicts+1 end
  end
 end
 return ids,conflicts
end
function E.remove_buses(s,ids,A)
 for _,id in ipairs(ids)do R.DeleteTrack(A.track(id,s.project))end
end
return E
