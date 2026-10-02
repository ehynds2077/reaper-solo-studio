-- Compare audio state while ignoring a narrow set of REAPER presentation fields.
-- Plugin payloads, parameters, bypass/offline flags, routing, items and envelopes
-- remain opaque and exact. Never trust an undo label as proof of a harmless edit.
local R=reaper
local S={}
local fx_ui={SHOW=true,LASTSEL=true,DOCKED=true,FLOATPOS=true,FLOAT=true,WNDRECT=true}
local track_ui={SEL=true,TRACKHEIGHT=true,PEAKCOL=true}
function S.window_action(label)
 return type(label)=='string'and (label:match('^Close FX config:')or label:match('^Close FX chain:')
  or label:match('^Open FX config:')or label:match('^Open FX chain:'))~=nil
end
function S.normalize(chunk)
 local out,stack={},{}
 for line in (chunk..'\n'):gmatch('([^\r\n]+)[\r\n]+')do
  local token=line:match('^%s*(%S+)');local scope=stack[#stack]
  local ui=((scope=='FXCHAIN'or scope=='FXCHAIN_REC'or scope=='TAKEFX'or scope=='CONTAINER')and fx_ui[token])
   or ((scope=='TRACK'or scope=='MASTERTRACK')and track_ui[token])
   or (scope=='ITEM'and token=='SEL')
  if not ui then out[#out+1]=line end
  if token and token:sub(1,1)=='<'then stack[#stack+1]=token:sub(2)
  elseif token=='>'then stack[#stack]=nil end
 end
 return table.concat(out,'\n')
end
function S.capture(project)
 -- Minimal test/older hosts keep the strict version guard if chunks are absent.
 if not R.GetTrackStateChunk or not R.GetMasterTrack then return nil end
 local parts={'mix-state-v1'}
 local function add(...)
  for i=1,select('#',...)do
   local v=select(i,...);parts[#parts+1]=type(v)=='number'and string.format('%.17g',v)or tostring(v)
  end
 end
 for i=-1,R.CountTracks(project)-1 do
  local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i)
  local ok,chunk=R.GetTrackStateChunk(tr,'',false)
  assert(ok and type(chunk)=='string'and #chunk>0,'Could not verify project audio state; mixing paused.')
  add(i,R.GetTrackGUID(tr),S.normalize(chunk))
 end
 if R.GetProjectTimeSignature2 then add(R.GetProjectTimeSignature2(project))end
 if R.Master_GetPlayRate then add(R.Master_GetPlayRate(project))end
 if R.GetGlobalAutomationOverride then add(R.GetGlobalAutomationOverride())end
 if R.CountTempoTimeSigMarkers then
  for i=0,R.CountTempoTimeSigMarkers(project)-1 do add(R.GetTempoTimeSigMarker(project,i))end
 end
 if R.EnumProjectMarkers3 then
  local i=0
  while true do
   local ok,region,start,finish,name,id,color=R.EnumProjectMarkers3(project,i)
   if ok==0 then break end
   add(region,start,finish,name,id,color);i=i+1
  end
 end
 if R.GetSetProjectInfo then
  for _,key in ipairs({'PROJECT_SRATE','PROJECT_SRATE_USE','PROJECT_TIMEBASE','PROJECT_TIMEBASE_FLAGS'})do
   add(key,R.GetSetProjectInfo(project,key,0,false))
  end
 end
 -- A compact 64-bit change fingerprint; no plugin blobs in the journal/logs.
 local text=table.concat(parts,'\0');local hash=0xcbf29ce484222325
 for i=1,#text do hash=(hash~text:byte(i))*0x100000001b3 end
 return string.format('v1:%016x:%d',hash,#text)
end
return S
