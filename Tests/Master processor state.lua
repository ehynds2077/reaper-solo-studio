-- Synthetic state fixtures; no licensed plugin assets are shipped.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
reaper={};local FX=dofile(root..'/Scripts/solo_mix_effects.lua');local n=0
local function check(ok,label)assert(ok,label);n=n+1;print('PASS '..label)end
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64(s)
 local out={}
 for i=1,#s,3 do
  local a,b,c=s:byte(i,i+2);local value=(a<<16)|((b or 0)<<8)|(c or 0)
  for shift=18,0,-6 do local index=(value>>shift)&63;out[#out+1]=(shift==6 and not b or shift==0 and not c)and '='or alphabet:sub(index+1,index+1)end
 end
 return table.concat(out)
end
local function replace(s,pos,len,v)return s:sub(1,pos-1)..v..s:sub(pos+len)end
local function integer(v)return v==0 and '\0'or string.char(1,v)end
local function prop(name,v)return name..'\0'..integer(#v)..v end
local function intprop(name,v)return prop(name,string.char(1)..string.pack('<I4',v))end
local function tree(name,props,children)return name..'\0'..integer(#props)..table.concat(props)..integer(#children)..table.concat(children)end
local function fixture(reconstructed,gain,internal_os,dirty,version)
 local props={prop('activePresetModified',string.char(dirty and 2 or 3)),prop('forceAudioUnitHighResolution',string.char(3))}
 if reconstructed then props[#props+1]=intprop('firstReconstructedVersionNumberID',version or 16034)end
 local data=tree('Data',{intprop('SATVersionNumber',16034)},{
  tree('CKAudioProcessorData',{}, {tree('PermanentData',props,{})}),
  tree('Parameters',{intprop('Input Gain',gain or 1),intprop('Oversampling',internal_os or 4)},{})})
 local payload=string.rep('\0',184)..data..string.rep('\0',8)
 payload=replace(payload,9,4,'VstW');payload=replace(payload,25,4,'CcnK')
 payload=replace(payload,1,4,string.pack('<I4',#payload-16));payload=replace(payload,29,4,string.pack('>I4',#payload-40));payload=replace(payload,181,4,string.pack('>I4',#data))
 local header=string.rep('\0',60);header=replace(header,1,4,string.pack('<I4',185483830));header=replace(header,49,4,string.pack('<I4',#payload))
 return 'BYPASS 0 0 0\n<VST "VST3: StandardCLIP (SIR Audio Tools)" StandardCLIP.vst3\n'..b64(header)..'\n'..b64(payload)..'\nAAAAAAAA\n>\nFXID {A}\nWAK 0 0\n'
end
local a=fixture(false);local b=fixture(true,nil,nil,true)
check(FX.same(a,b),'Only reconstruction metadata and preset dirty indicator are ignored')
check(not FX.same(a,fixture(true,2)),'Different input gain remains significant')
check(not FX.same(a,fixture(true,nil,8)),'Internal oversampling remains significant')
check(not FX.same(a,b:gsub('BYPASS 0','BYPASS 1')),'Host bypass remains significant')
check(not FX.same(a,b:gsub('FXID','FX_OVERSAMPLE 2\nFXID')),'Host oversampling remains significant')
check(not FX.same(a,fixture(true,nil,nil,nil,16035)),'Unknown reconstruction version is not normalized')
check(not FX.same(a:gsub('StandardCLIP','DifferentPlugin'),b:gsub('StandardCLIP','DifferentPlugin')),'Metadata exception is specific to StandardCLIP')
check(not FX.same(a,b:gsub('AAAAAAAA','????')),'Unknown or malformed payload stays exact')
local function api(count)
 reaper={TrackFX_GetNumParams=function()return count end,
 TrackFX_GetParamName=function(_,_,i)return true,(i<96 or i==count-1)and ('Audio '..i)or ('MIDI CC '..i)end,
 TrackFX_GetParam=function()return .5,0,1 end,GetFXEnvelope=function()return nil end,
 TrackFX_GetFormattedParamValue=function()return true,'0 dB'end,TrackFX_GetParamNormalized=function()return .5 end}
 return dofile(root..'/Scripts/solo_mix_processors.lua')
end
local P=api(6000);local first=P.inspect({},0)
check(#first.parameters==96 and first.next_start==96,'First parameter page preserves native cursor')
local middle=P.inspect({},0,first.next_start)
check(#middle.parameters==0 and middle.next_start==4192,'Scan budget advances across an empty MIDI-only page')
local last=P.inspect({},0,middle.next_start)
check(#last.parameters==1 and last.parameters[1].index==5999 and last.next_start==nil,'Last audio parameter keeps original index after skipped pages')
check(#P.inspect({},0,96,true).parameters==96,'Explicit MIDI inspection includes placeholders')
P=api(0);local empty=P.inspect({},0)
check(#empty.parameters==0 and empty.next_start==nil,'Zero-parameter plugins inspect cleanly')
check(not pcall(P.inspect,{},0,-1),'Invalid parameter offsets are rejected')
print(n..' master processor state checks passed')
