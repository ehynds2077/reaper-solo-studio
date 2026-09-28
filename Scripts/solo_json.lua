-- Small JSON codec for local IPC. No Lua evaluation of model or file content.
local J={null={}}
local array_mt={__json_array=true}
function J.array(t)return setmetatable(t or {},array_mt)end
local escapes={['"']='\\"',['\\']='\\\\',['\b']='\\b',['\f']='\\f',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
local function quote(s)return '"'..s:gsub('[%z\1-\31\\"]',function(c)return escapes[c]or string.format('\\u%04x',c:byte())end)..'"'end
function J.encode(v)
 local t=type(v)
 if v==J.null or t=='nil'then return 'null' end
 if t=='boolean'then return tostring(v)end
 if t=='number'then assert(v==v and math.abs(v)<math.huge,'Non-finite JSON number');return string.format('%.17g',v)end
 if t=='string'then return quote(v)end
 assert(t=='table','Unsupported JSON value')
 local out={};local array=getmetatable(v)==array_mt or #v>0
 if array then for i=1,#v do out[i]=J.encode(v[i])end;return '['..table.concat(out,',')..']'end
 for k,x in pairs(v)do assert(type(k)=='string','JSON object key');out[#out+1]=quote(k)..':'..J.encode(x)end
 table.sort(out);return '{'..table.concat(out,',')..'}'
end
function J.decode(s)
 assert(type(s)=='string'and #s<16000000,'Invalid JSON input');local p=1;local value
 local function ws()local _,e=s:find('^%s*',p);p=(e or p-1)+1 end
 local function str()
  assert(s:sub(p,p)=='"','Expected JSON string');p=p+1;local out={}
  while p<=#s do
   local c=s:sub(p,p);p=p+1
   if c=='"'then return table.concat(out)end
   if c=='\\'then
    c=s:sub(p,p);p=p+1
    local map={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
    if c=='u'then
     local h=s:sub(p,p+3);assert(h:match('^%x%x%x%x$'),'Invalid Unicode escape');local n=tonumber(h,16);p=p+4
     if n>=0xd800 and n<=0xdbff then
      assert(s:sub(p,p+1)=='\\u','Missing surrogate');local lo=tonumber(s:sub(p+2,p+5),16)
      assert(lo and lo>=0xdc00 and lo<=0xdfff,'Invalid surrogate');p=p+6;n=0x10000+(n-0xd800)*1024+lo-0xdc00
     else assert(n<0xdc00 or n>0xdfff,'Invalid surrogate')end
     out[#out+1]=utf8.char(n)
    else assert(map[c],'Invalid JSON escape');out[#out+1]=map[c]end
   else assert(c:byte()>=32,'Control character in JSON');out[#out+1]=c end
  end
  error('Unterminated JSON string')
 end
 value=function(depth)
  assert(depth<64,'JSON nesting limit');ws();local c=s:sub(p,p)
  if c=='"'then return str()end
  if c=='['or c=='{'then
   local arr=c=='[';local out=arr and J.array()or {};local ending=arr and ']'or '}';p=p+1;ws()
   if s:sub(p,p)==ending then p=p+1;return out end
   while true do
    local k;if not arr then ws();k=str();ws();assert(s:sub(p,p)==':','Expected colon');p=p+1 end
    local v=value(depth+1);if arr then out[#out+1]=v else assert(out[k]==nil,'Duplicate JSON key');out[k]=v end
    ws();c=s:sub(p,p);p=p+1;if c==ending then break end;assert(c==',','Expected JSON comma')
   end
   return out
  end
  for k,v in pairs({['true']=true,['false']=false,['null']=J.null})do if s:sub(p,p+#k-1)==k then p=p+#k;return v end end
  local token=s:match('^%-?%d+%.?%d*[eE]?[+-]?%d*',p)
  assert(token and not token:match('^%-?0%d')and not token:match('%.$'),'Invalid JSON number')
  local n=tonumber(token);assert(n and n==n and math.abs(n)<math.huge,'Invalid JSON number');p=p+#token;return n
 end
 local result=value(0);ws();assert(p>#s,'Trailing JSON data');return result
end
function J.read(path)local f=io.open(path,'rb');if not f then return nil end;local s=f:read('*a');f:close();return J.decode(s)end
function J.write(path,data)local f=assert(io.open(path..'.tmp','wb'));f:write(J.encode(data));f:close();assert(os.rename(path..'.tmp',path))end
return J
