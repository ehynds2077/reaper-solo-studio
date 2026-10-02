-- Snapshot and restore individual existing FX, including opaque plugin state
-- and parameter envelopes. Never replace a track's media/routing/other effects.
local R=reaper;local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local State=dofile(dir..'/solo_mix_state.lua')
local PluginState=dofile(dir..'/solo_mix_plugin_state.lua')
local F={}
function F.blocks(chunk)
 local rows,stack,current={},{};local position=1
 for line in (chunk:sub(-1)=='\n'and chunk or chunk..'\n'):gmatch('([^\n]*\n)')do
  local token=line:match('^%s*(%S+)');local scope=stack[#stack]
  if #stack==2 and scope=='FXCHAIN'and (token=='BYPASS'or token=='>')then
   if current then current.finish=position-1;rows[#rows+1]=current;current=nil end
   if token=='BYPASS'then current={start=position}end
  end
  if current and #stack==2 and token=='FXID'then current.id=line:match('FXID%s+(%S+)')end
  if token and token:sub(1,1)=='<'then stack[#stack+1]=token:sub(2)
  elseif token=='>'then stack[#stack]=nil end
  position=position+#line
 end
 return rows
end
local function block(chunk,id)
 for _,row in ipairs(F.blocks(chunk))do if row.id==id then return row end end
 error('Could not snapshot this effect in the track FX chain')
end
function F.capture(tr,id)
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok,'Could not read plugin state')
 local row=block(chunk,id);return chunk:sub(row.start,row.finish)
end
function F.same(a,b)
 local function normalized(value)
  -- REAPER inserts its default "Program 1" name into an empty VST host
  -- trailer when loading a snapshot. This exact host-metadata substitution
  -- is not a change to the plugin state payload preceding it.
  value=value:gsub('(<VST[^\n]*\n.-)\nAAAQAAAA(\r?\n%s*>)','%1\nAFByb2dyYW0gMQAQAAAA%2')
  value=PluginState.normalize(value)
  return State.normalize('<FXCHAIN\n'..value..'>\n')
 end
 return type(a)=='string'and type(b)=='string'and normalized(a)==normalized(b)
end
function F.plan(tr,replacements)
 local ok,chunk=R.GetTrackStateChunk(tr,'',false);assert(ok,'Could not read track for plugin restore')
 local before=chunk
 for id,value in pairs(replacements)do
  assert(type(value)=='string','Missing plugin snapshot')
  local saved=block('<TRACK\n<FXCHAIN\n'..value..'>\n>\n',id)
  assert(saved,'Invalid plugin snapshot')
  local row=block(chunk,id);chunk=chunk:sub(1,row.start-1)..value..chunk:sub(row.finish+1)
 end
 return {track=tr,before=before,after=chunk,replacements=replacements}
end
function F.apply(plans)
 local written={}
 local ok,err=xpcall(function()
  for _,plan in ipairs(plans)do
   written[#written+1]=plan
   assert(R.SetTrackStateChunk(plan.track,plan.after,false),'REAPER could not restore plugin state')
   for id,value in pairs(plan.replacements)do
    assert(F.same(F.capture(plan.track,id),value),'Restored plugin state did not match its snapshot')
   end
  end
 end,debug.traceback)
 if not ok then
  for i=#written,1,-1 do R.SetTrackStateChunk(written[i].track,written[i].before,false)end
  error(err)
 end
end
function F.set_offline_enabled(tr,id,enabled)
 assert(type(enabled)=='boolean','enabled must be a boolean')
 local before=F.capture(tr,id)
 -- TrackFX_SetEnabled ignores offline FX. Update only its stored bypass bit,
 -- retaining the offline flag, opaque plugin data and parameter envelopes.
 -- Do not load the plugin just to change its bypass state.
 local after,count=before:gsub('^(%s*BYPASS%s+)[01](%s+1%s+)',function(prefix,suffix)
  return prefix..(enabled and '0'or '1')..suffix
 end,1)
 assert(count==1,'Expected an offline plugin snapshot')
 if before~=after then F.apply({F.plan(tr,{[id]=after})})end
end
return F
