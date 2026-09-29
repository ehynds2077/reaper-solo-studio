local R=reaper
return function(B)
 local P={};local J=B.json;local job;local state;local lastlease=0
 local root=(os.getenv('HOME')or '')..'/Library/Application Support/Solo Studio/Bounce playback'
 local function write_lease()local f=assert(io.open(job..'/lease','w'));f:write(tostring(os.time()));f:close();lastlease=R.time_precise()end
 function P.stop()
  if job then J.write(job..'/control.json',{state='stop'});job=nil end
  state=nil
 end
 function P.play(row,variant)
  assert(R.GetPlayState()==0,'Stop the song before listening to a bounce.')
  assert(row.status=='ready','Wait for this bounce to finish archiving.')
  P.stop();job=root..'/'..R.genGuid():gsub('[^%w]','');R.RecursiveCreateDirectory(job,0)
  J.write(job..'/request.json',{path=row.folder..'/'..(variant=='instrumental'and 'Instrumental.wav'or 'Full mix.wav')})
  J.write(job..'/control.json',{state='playing'});write_lease()
  state={state='starting',position=0,id=row.id,variant=variant,project=R.EnumProjects(-1,'')}
  B.launch({'preview',job})
 end
 function P.pause()
  if not job or not state then return end
  local mode=state.state=='paused'and 'playing'or 'paused';J.write(job..'/control.json',{state=mode});state.state=mode
 end
 function P.poll()
  if not job then return end
  if R.GetPlayState()~=0 or R.EnumProjects(-1,'')~=state.project then P.stop();return end
  if R.time_precise()-lastlease>1 then write_lease()end
  local ok,fresh=pcall(J.read,job..'/status.json')
  if ok and fresh then
   for k,v in pairs(fresh)do state[k]=v end
   if state.state=='stopped'or state.state=='failed'then job=nil end
  end
 end
 function P.state()return state end
 return P
end
