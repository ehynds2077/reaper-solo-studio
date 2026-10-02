-- Narrow read-only equivalence for StandardCLIP's first state reconstruction.
-- No audio parameters or unknown vendor bytes are discarded or rewritten.
local M={};local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local codes={};for i=1,64 do codes[alphabet:sub(i,i)]=i-1 end
local function decode(s)
 assert(#s<4000000 and #s%4==0 and not s:find('[^%w+/=]'))
 local out,bits,n={},0,0
 for c in s:gmatch('.')do if c~='='then bits=(bits<<6)|assert(codes[c]);n=n+6;if n>=8 then n=n-8;out[#out+1]=string.char((bits>>n)&255);bits=bits&((1<<n)-1)end end end
 return table.concat(out)
end
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function replace(s,pos,len,value)return s:sub(1,pos-1)..value..s:sub(pos+len)end
local function canonical(header,payload)
 assert(#header==60 and string.unpack('<I4',header)==185483830)
 assert(string.unpack('<I4',header,49)==#payload and payload:sub(9,12)=='VstW'and payload:sub(25,28)=='CcnK')
 assert(string.unpack('<I4',payload)==#payload-16 and string.unpack('>I4',payload,29)==#payload-40)
 local size=string.unpack('>I4',payload,181);assert(size>0 and size+192==#payload)
 local tree=payload:sub(185,184+size);local pos=1;local removed,root_version,dirtypos
 local function integer()
  local start=pos;local bytes=assert(tree:byte(pos));pos=pos+1;assert(bytes<=4)
  local n=0;for i=0,bytes-1 do n=n|(assert(tree:byte(pos))<<(8*i));pos=pos+1 end
  return n,start,pos-start
 end
 local function str()local finish=assert(tree:find('\0',pos,true));local s=tree:sub(pos,finish-1);pos=finish+1;return s end
 local node
 node=function(path,depth)
  assert(depth<24);local name=str();local full=path..'/'..name;local count,countpos,countlen=integer();assert(count<512)
  for _=1,count do
   local start=pos;local key=str();local len=integer();assert(len<=#tree-pos+1)
   local valuepos=pos;local value=tree:sub(pos,pos+len-1);pos=pos+len
   if full=='/Data/CKAudioProcessorData/PermanentData'and key=='activePresetModified'then
    assert(len==1 and (value:byte(1)==2 or value:byte(1)==3));dirtypos=valuepos
   end
   if full=='/Data'and key=='SATVersionNumber'then root_version=value end
   if full=='/Data/CKAudioProcessorData/PermanentData'and key=='firstReconstructedVersionNumberID'then
    assert(not removed and len==5 and value:byte(1)==1 and value==root_version and count<256 and countlen==2)
    removed={start=start,finish=pos-1,countpos=countpos,count=count}
   end
  end
  local children=integer();assert(children<512);for _=1,children do node(full,depth+1)end
 end
 node('',0)
 -- The preset-browser dirty indicator is UI metadata, not an audio control.
 if dirtypos then payload=replace(payload,184+dirtypos,1,string.char(3))end
 -- Preserve other trees/trailers inside the vendor chunk verbatim.
 if removed then
  local len=removed.finish-removed.start+1
  payload=replace(payload,184+removed.start,len,'')
  payload=replace(payload,184+removed.countpos,2,string.char(1,removed.count-1))
  payload=replace(payload,181,4,string.pack('>I4',size-len))
  payload=replace(payload,29,4,string.pack('>I4',#payload-40))
  payload=replace(payload,1,4,string.pack('<I4',#payload-16))
  header=replace(header,49,4,string.pack('<I4',#payload))
 end
 return hex(header)..'\n'..hex(payload)
end
function M.normalize(value)
 return(value:gsub('(<VST "VST3: StandardCLIP %(SIR Audio Tools%)"[^\n]*\n)(.-)(\n%s*>)',function(prefix,data,suffix)
  local lines={};for line in data:gmatch('[^\r\n]+')do lines[#lines+1]=line end
  if #lines<3 then return prefix..data..suffix end
  local ok,normal=pcall(function()
   return canonical(decode(lines[1]),decode(table.concat(lines,'',2,#lines-1)))
  end)
  if not ok then return prefix..data..suffix end -- Unknown versions remain exact.
  return prefix..normal..'\n'..lines[#lines]..suffix
 end))
end
return M
