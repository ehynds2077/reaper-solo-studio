-- Read native peak meters without changing monitoring, routing or peak holds.
local R=reaper
return function()
 local M={};local project,now,cache,rows=nil,0,{},{}
 local floor,release,hold=-60,24,1.2
 local function db(value)
  if type(value)~='number'or value~=value or value<=0 or value==math.huge then return floor end
  return math.max(floor,20*math.log(value,10))
 end
 function M.reset()project=nil;cache={};rows={}end
 function M.begin_frame(p,time)
  if p~=project then M.reset();project=p end
  now=time;cache={}
 end
 function M.read(row)
  local values={floor,floor};local keys={}
  for _,member in ipairs(row.members)do
   keys[#keys+1]=member.key
   local peak=cache[member.key]
   if not peak then
    peak={db(R.Track_GetPeakInfo(member.track,0)),db(R.Track_GetPeakInfo(member.track,1))}
    cache[member.key]=peak
   end
   for ch=1,2 do values[ch]=math.max(values[ch],peak[ch])end
  end
  local signature=table.concat(keys,'\n');local state=rows[row.key]
  if not state or state.members~=signature then
   state={members=signature,level={floor,floor},peak={floor,floor},until_time={0,0},time=now,clipped=false}
   rows[row.key]=state
  end
  local elapsed=math.max(0,now-state.time);state.time=now
  for ch=1,2 do
   state.level[ch]=math.max(values[ch],state.level[ch]-release*elapsed)
   if values[ch]>=state.peak[ch]then state.peak[ch]=values[ch];state.until_time[ch]=now+hold
   elseif now>state.until_time[ch]then
    local decay=release*math.min(elapsed,now-state.until_time[ch])
    state.peak[ch]=math.max(state.level[ch],state.peak[ch]-decay)
   end
   state.clipped=state.clipped or values[ch]>=0
  end
  return state
 end
 function M.clear(key)rows[key]=nil end
 function M.position(value)return math.max(0,math.min(1,(value-floor)/-floor))end
 return M
end
