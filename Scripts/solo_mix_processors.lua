-- Physical-unit controls for verified native master processors. The bridge owns
-- automation protection, durable snapshots and rollback of the entire FX block.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua');local R=reaper;local P={}
P.names={configure_tape=true,configure_bus_compressor=true,configure_clipper=true}
P.ampex='VST3: UADx Ampex ATR-102 Master Tape (Universal Audio (UADx))'
P.ssl='VST3: UADx SSL G Bus Compressor (Universal Audio (UADx))'
P.clipper='VST3: StandardCLIP (SIR Audio Tools)'
P.preset_path='/Library/Application Support/Universal Audio/Plug-Ins/uaudio_ampex_atr-102_tape.lunacomponent/algo.bundle/Contents/Resources/presets/Clean_Ultralinear_Master.json'
local tape_labels={'Auto Gain','L Rec Level','R Rec Level','L Repro Level','R Repro Level','Path Select','IPS','Tape Type','Cal Level','Head Width','Emphasis EQ','Auto Cal','L HF EQ','R HF EQ','L Shelf EQ','R Shelf EQ','L Repro HF EQ','R Repro HF EQ','L Repro LF EQ','R Repro LF EQ','L Bias','R Bias','Crosstalk','Wow & Flutter','Hiss & Hum','Transformer','Stereo Link','Meter','Power','Master Bypass'}
local function finite(v,lo,hi)assert(type(v)=='number'and v==v and v>=lo and v<=hi,'Value outside supported processor range');return v end
local function label(tr,fx,i,name)local ok,actual=R.TrackFX_GetParamName(tr,fx,i,'');assert(ok and actual==name,'Processor parameter layout differs: expected '..name)end
local function numeric(text)return tonumber(text:match('[+-]?%d+%.?%d*'))end
local function formatted(tr,fx,i)local ok,text=R.TrackFX_GetFormattedParamValue(tr,fx,i,'');assert(ok,'Could not read processor parameter');return text end
local function write(tr,fx,i,value)
 assert(R.TrackFX_SetParamNormalized(tr,fx,i,value),'Processor rejected parameter')
 assert(math.abs(R.TrackFX_GetParamNormalized(tr,fx,i)-value)<1e-4,'Processor normalized readback differs')
end
-- Invert the plugin's own monotonic formatter without modifying audio state.
local function unit(tr,fx,i,target,tolerance)
 local lo,hi=0,1
 for _=1,32 do
  local mid=(lo+hi)/2;local ok,text=R.TrackFX_FormatParamValueNormalized(tr,fx,i,mid,'')
  local v=ok and numeric(text);assert(v,'Processor does not expose a usable unit mapping')
  if math.abs(v-target)<=tolerance then return mid end
  if v<target then lo=mid else hi=mid end
 end
 error('Requested processor value is not representable')
end
local function decode64(s)
 assert(type(s)=='string'and #s==208 and not s:find('[^%w+/=]'),'Unknown UA preset payload')
 local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
 local map={};for i=1,#alphabet do map[alphabet:sub(i,i)]=i-1 end
 local out={};local bits,n=0,0
 for c in s:gmatch('.')do if c~='='then bits=(bits<<6)|assert(map[c]);n=n+6;if n>=8 then n=n-8;out[#out+1]=string.char((bits>>n)&255);bits=bits&((1<<n)-1)end end end
 return table.concat(out)
end
function P.tape_preset()
 -- Read the user's installed factory asset; do not ship vendor preset data.
 local j=assert(J.read(P.preset_path),'Clean Ultralinear Master factory preset is not installed at the supported macOS location')
 assert(j.name=='Clean Ultralinear Master'and j.plugin_id=='uaudio_ampex_atr-102_tape'and j.version==1,'Unknown UA factory preset format')
 local b=decode64(j.chunk)
 assert(#b==156 and string.unpack('<I4',b)==1 and b:sub(5,40)==string.rep('\0',36),'Unknown UA preset state layout')
 local values={};for i=0,28 do values[i]=finite(string.unpack('<f',b,41+i*4),0,1)end
 return values
end
function P.describe(plugin)
 if plugin==P.ampex then return {tool='configure_tape',preferred_preset='Clean Ultralinear Master',preset_available=pcall(P.tape_preset)}end
 if plugin==P.ssl then return {tool='configure_bus_compressor'}end
 if plugin==P.clipper then return {tool='configure_clipper',role='Peak shaving before the final true-peak limiter'}end
end
function P.inspect(tr,fx,start,include_midi)
 local count=R.TrackFX_GetNumParams(tr,fx);start=start or 0;finite(start,0,math.max(0,count-1));assert(start%1==0,'Integer parameter offset required')
 local params=J.array();local i=start;local skipped=0
 -- Keep native indices/cursor even when skipping thousands of UAD MIDI CCs.
 -- Bound the scan as well as the result so unusually large plugins paginate.
 while i<count and i<start+4096 and #params<96 do
  local _,name=R.TrackFX_GetParamName(tr,fx,i,'')
  if include_midi or not name:match('^MIDI CC')then
   local raw,lo,hi=R.TrackFX_GetParam(tr,fx,i);local env=R.GetFXEnvelope(tr,fx,i,false);local automated=false
   if env then local ok,chunk=R.GetEnvelopeStateChunk(env,'',false);automated=not ok or chunk:match('\nACT%s+1')~=nil end
   params[#params+1]={index=i,name=name,formatted=formatted(tr,fx,i),raw=raw,min=lo,max=hi,normalized=R.TrackFX_GetParamNormalized(tr,fx,i),automated=automated}
  else skipped=skipped+1 end
  i=i+1
 end
 return {parameters=params,total_parameters=count,skipped_midi_parameters=skipped,next_start=i<count and i or nil}
end
function P.configure(name,tr,fx,plugin,a,protect)
 assert(not R.TrackFX_GetOffline(tr,fx),'Load this effect with set_effect_state offline=false first')
 local values={};local function add(i,l,v,expected,tolerance)label(tr,fx,i,l);values[#values+1]={i=i,value=v,expected=expected,tolerance=tolerance or .11}end
 local function db(i,l,v,lo,hi,tolerance)finite(v,lo,hi);label(tr,fx,i,l);add(i,l,unit(tr,fx,i,v,tolerance or .04),v,tolerance)end
 local preset
 if name=='configure_tape'then
  assert(plugin==P.ampex,'This tape adapter requires native VST3 UADx Ampex ATR-102')
  for i,l in ipairs(tape_labels)do label(tr,fx,i-1,l)end
  assert(a.preset~=nil or a.input_db~=nil or a.output_db~=nil,'Supply preset and/or input/output gain')
  if a.preset~=nil then assert(a.preset=='Clean Ultralinear Master','Unsupported tape preset');preset=P.tape_preset()end
  -- Temporarily disable linked controls while writing absolute stereo values.
  add(0,tape_labels[1],0);add(26,tape_labels[27],0);if preset then add(11,tape_labels[12],0)end
  if preset then for i=1,28 do if i~=11 and i~=26 then add(i,tape_labels[i+1],preset[i])end end end
  if a.input_db~=nil then db(1,'L Rec Level',a.input_db,-40,9.5);db(2,'R Rec Level',a.input_db,-40,9.5)end
  if a.output_db~=nil then db(3,'L Repro Level',a.output_db,-40,9.3);db(4,'R Repro Level',a.output_db,-40,9.3)end
  if preset then add(11,'Auto Cal',preset[11])end
  add(26,'Stereo Link',1);add(28,'Power',1,'On');add(29,'Master Bypass',0,'Off')
  local autogain=a.auto_gain
  if autogain~=nil then assert(type(autogain)=='boolean','auto_gain must be boolean')
  else autogain=a.input_db==nil and a.output_db==nil and (preset and preset[0]or R.TrackFX_GetParamNormalized(tr,fx,0))>=.5 end
  add(0,'Auto Gain',autogain and 1 or 0,autogain and 'On'or 'Off')
 elseif name=='configure_bus_compressor'then
  assert(plugin==P.ssl,'This bus compressor adapter requires native VST3 UADx SSL G Bus Compressor')
  db(0,'Thresh',a.threshold_db,-15,15)
  db(1,'Make Up',a.makeup_db or 0,0,15)
  local attack=a.attack_ms or 30;local attacks={[.1]=0,[.3]=.2,[1]=.4,[3]=.6,[10]=.8,[30]=1};assert(attacks[attack],'Unsupported SSL attack')
  add(2,'Attack',attacks[attack],attack,.001)
  local release=a.release or 'auto';local releases={['100ms']={0,.1},['300ms']={.25,.3},['600ms']={.5,.6},['1200ms']={.75,1.2},auto={1,'Auto'}}
  local rel=assert(releases[release],'Unsupported SSL release');add(3,'Release',rel[1],rel[2],.001)
  local ratio=a.ratio or 2;local ratios={[2]=0,[4]=.5,[10]=1};assert(ratios[ratio],'Unsupported SSL ratio');add(4,'Ratio',ratios[ratio],tostring(ratio)..':1')
  local sc=a.sidechain_hpf_hz or 80
  if sc==0 then add(5,'SC Filter',0,'Off')else db(5,'SC Filter',sc,20,500,.51)end
  local mix=finite(a.mix_percent or 100,0,100);add(7,'Mix',mix/100,mix,.51)
  add(10,'Power',1,'On');add(11,'Master Bypass',0,'Off')
 elseif name=='configure_clipper'then
  assert(plugin==P.clipper,'This clipper adapter requires VST3 StandardCLIP')
  db(0,'Input Gain',a.input_db or 0,-24,24,.02);db(1,'Output Gain',a.output_db or 0,-24,24,.02)
  db(5,'Clipping',a.clipping_db,-24,0,.02)
  add(2,'Softness',finite(a.softness_percent or 0,0,100)/100)
  -- Only this mode has a validated mapping in the installed VST3. Other mode
  -- values return empty labels, so do not pretend they are calibrated controls.
  add(6,'Clip Type',0,'Soft Clip Classic');add(7,'Bypass',0,'Off')
 else error('Unknown processor adapter')end
 local parameters={};for _,v in ipairs(values)do parameters[#parameters+1]=v.i end
 local shift
 if name=='configure_clipper'and a.oversampling~=nil then
  shift=({['96k']=1,['192k']=2,['384k']=3})[a.oversampling];assert(shift,'Unsupported host oversampling target')
  assert(R.GetAllProjectPlayStates()==0,'Stop playback before changing host oversampling')
 end
 protect(tr,fx,parameters,a.override_automation)
 for _,v in ipairs(values)do write(tr,fx,v.i,v.value)end
 -- Verify AFTER all writes, including linked controls which may change siblings.
 local last={};for _,v in ipairs(values)do last[v.i]=v end
 local readback=J.array()
 for i=0,R.TrackFX_GetNumParams(tr,fx)-1 do if last[i]then
  local v=last[i];assert(math.abs(R.TrackFX_GetParamNormalized(tr,fx,i)-v.value)<1e-4,'Linked processor control changed another setting')
  local actual=formatted(tr,fx,i)
  if type(v.expected)=='number'then local n=numeric(actual);assert(n and math.abs(n-v.expected)<=v.tolerance,'Processor physical value differs from requested value')
  elseif v.expected then assert(actual==v.expected,'Processor mode differs from requested mode')end
  local _,l=R.TrackFX_GetParamName(tr,fx,i,'');readback[#readback+1]={index=i,name=l,formatted=actual}
 end end
 if shift then assert(R.TrackFX_SetNamedConfigParm(tr,fx,'instance_oversample_shift',tostring(shift)),'Host oversampling unavailable')end
 local osok,os=R.TrackFX_GetNamedConfigParm(tr,fx,'instance_oversample_shift')
 if shift then assert(osok and tonumber(os)==shift,'Host oversampling readback differs')end
 return {plugin=plugin,parameters=readback,preset=a.preset,preset_method=preset and 'Installed UA factory parameter state (validated against UA preset browser)'or nil,
  host_oversampling_shift=osok and tonumber(os)or nil,enabled=R.TrackFX_GetEnabled(tr,fx),
  next_step='Verify enabled state and chain order, then render. Clipper oversampling is REAPER host oversampling, not the internal plugin setting. Clipping does not guarantee a true-peak ceiling.'}
end
return P
