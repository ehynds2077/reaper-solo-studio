-- Native Mix tab; network and analysis run in a separate Python process.
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local B=dofile(dir..'/solo_mix_bridge.lua');local J=B.json;local R=reaper
local Models=dofile(dir..'/solo_models.lua')
return function(M,ui,options)
 local X={};local text,button,color,C=ui.text,ui.button,ui.color,ui.colors
 local data=options and options.data or (os.getenv('HOME')or '')..'/Library/Application Support/Solo Studio/Mix'
 R.RecursiveCreateDirectory(data..'/sessions',0)
 local worker_dir=dir..'/Mix'
 local worker_file=io.open(worker_dir..'/worker.py','r')
 if worker_file then worker_file:close()else worker_dir=dir..'/../Mix'end
 local function quote(s)assert(not s:find('[\r\n"]'),'Unsupported path');return '"'..s..'"'end
 local function launch(args)
  local command='/usr/bin/python3 '..quote(worker_dir..'/worker.py')
  for _,a in ipairs(args)do command=command..' '..quote(a)end
  local result=R.ExecProcess(command,-1);assert(result,'Could not start Python worker')
 end
 local function read(path,default)local ok,value=pcall(J.read,path);return ok and value or default end
 local models=Models.new(J,R,data,launch)
 local config=read(data..'/settings.json',{})
 config.model=config.model or Models.default
 config.direction=config.direction or 'Natural indie rock. Clear vocals, punchy drums, preserve dynamics and performance.'
 config.rounds=config.rounds or 60;config.stop_after_usd=config.stop_after_usd or 2
 config.target_lufs=config.target_lufs or -12
 if config.visual_analysis==nil then config.visual_analysis=true end
 local lib=read(data..'/library.json',{references=J.array(),default=''})
 local selected=config.references or (lib.default~=''and J.array({lib.default})or J.array())
 local phase='intro';local session;local state;local status='Choose a reference and direction, then create a candidate mix.'
 local lastpoll=0;local handled='';local chat_scroll=0;local full_song=false;local importing=false;local checking=false;local show_graphs=false
 local graph_mode='spectrogram';local graphics;local graphics_working=false;local graph_image;local graph_slot=701
 local model_x,model_y=24,215
 local mix_view=R.GetExtState(M.ns,'mix_view')=='bounces'and 'bounces'or 'ai'
 local library
 local function bounces()
  if not library then library=dofile(dir..'/solo_bounces_view.lua')({text=text,button=button,color=color,colors=C,run=ui.run,busy=function()return X.busy()end})end
  return library
 end
 local function recover_review(recovered)
  local f=io.open(recovered.path..'/cancel','w');if f then f:close()end
  local saved=read(recovered.path..'/status.json',{events=J.array()})
  -- Completed work resumes review; interrupted work may be refined or reverted.
  if recovered.recovery_changed then
   saved.state='stale';phase='recovery'
   status='This project has changed since its previous AI mix.'
  elseif saved.state=='review'or saved.state=='review_warning'then
   status='Candidate recovered. Play and switch Original / Candidate to compare.'
  else saved.state='recovery';status='Unfinished session recovered. Revert restores its faders and removes its added effects.'end
  return saved
 end
 session=B.find_session(data..'/sessions',R.GetExtState(M.ns,'mix_session'))
 if session then
  phase='session';state=recover_review(session)
 end
 local function clear_legacy()
  if session and R.GetExtState(M.ns,'mix_session')==session.path then R.SetExtState(M.ns,'mix_session','',true)end
 end
 local function save_config()config.references=selected;J.write(data..'/settings.json',config)end
 local function connection()return read(data..'/connection.json',{connected=false,message='Connect your OpenRouter account to begin.'})end
 local function bounds()
  local s,e=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
  if full_song or e<=s then s=0;e=R.GetProjectLength(0)end
  return {s,e}
 end
 local function cancelled()
  if session then local f=assert(io.open(session.path..'/cancel','w'));f:close()end
 end
 local function worker_active()
  local worker=session and read(session.path..'/worker.json')
  if not worker or not worker.active or type(worker.pid)~='number'or worker.pid<1 or worker.pid%1~=0 then return false end
  local result=R.ExecProcess('/bin/kill -0 '..string.format('%d',worker.pid),1000)
  return result and result:match('^0[\r\n]')~=nil
 end
 local function stopped(reason,message)
  cancelled()
  local details={reason=reason,message=message,time=os.time(),context=B.diagnostics(session)}
  J.write(session.path..'/panel-stop.json',details);B.trace(session,'panel_stopped',details)
  state.state='error';state.events=state.events or J.array();state.events[#state.events+1]={role='status',text=message,time=os.time()}
  state.panel_stop=details;J.write(session.path..'/status.json',state);status=message
 end
 function X.busy()return session and not session.finished and state and state.state=='running'end
 function X.pending()return session and not session.finished end
 local function finish(revert)
  assert(session,'No session');cancelled()
  if revert then
   local conflicts=B.revert(session)
   status=conflicts>0 and ('Reverted; preserved '..conflicts..' fader/pan controls you changed manually.')or 'Original mix restored. Recordings and existing effects are preserved.'
  else
   assert(state and state.state=='review','Only a measured candidate with peaks at or below -1 dBTP can be kept.')
   B.keep(session);status='Candidate kept. Save your REAPER project when you are ready.'
  end
  clear_legacy();session=nil;phase='intro';state=nil
 end
 local function restart()
  assert(session and not X.busy(),'Wait for the current pass before starting a new mix.')
  cancelled();B.archive_current(session)
  clear_legacy();session=nil;state=nil;phase='setup'
  status='Current mix preserved. Choose references and create a new candidate.'
 end
 function X.poll()
  if library then library.poll()end
  if R.time_precise()-lastpoll<.2 then return end;lastpoll=R.time_precise()
  models.poll()
  if checking then local c=read(data..'/connection.json');if c then checking=false;status=c.message end end
  if importing then local v=read(data..'/import-result.json');if v then importing=false;status=v.error or ('Reference saved: '..v.title);lib=read(data..'/library.json',lib)end end
  if not session or session.finished then return end
  graphics=read(session.path..'/graphics.json')
  if graphics_working then
   local result=read(session.path..'/graphics-status.json')
   if result then graphics_working=false;if result.state=='error'then status=result.message end end
  end
  if state and (state.state=='recovery'or state.state=='stale')then return end
  local fresh=read(session.path..'/status.json');if fresh and not (state and state.state=='error')then state=fresh end
  if state and (state.state=='review'or state.state=='review_warning')then
   status=state.reference_issues and #state.reference_issues>0 and ('Reference target not reached: '..state.reference_issues[1])or 'Play and switch Original / Candidate to compare. Keep the mix when you are happy with it.'
  end
  if X.busy()then
   local ok,err=pcall(B.guard,session,true)
   if not ok then stopped('guard_rejected',tostring(err));return end
   if state.updated and os.time()-state.updated>420 then stopped('worker_timeout','Worker timed out. Review the candidate before continuing.');return end
  end
  local req=read(session.path..'/request.json')
  if req and req.id~=handled and X.busy()then
   handled=req.id
   B.trace(session,'request_received',{id=req.id,tool=req.name})
   local ok,result=pcall(B.execute,session,req.name,req.arguments)
   local response=ok and {result=result}or {error=tostring(result):match('^[^\n]+'),fatal=false}
   J.write(session.path..'/response-'..req.id..'.json',response)
   B.trace(session,'request_finished',{id=req.id,tool=req.name,error=response.error,context=not ok and B.diagnostics(session)or nil})
  end
 end
 local function start(options)
  options=options or {}
  assert(not X.pending(),'Keep or revert the current session first.')
  assert(connection().connected,'Connect and refresh OpenRouter first.')
  local range=options.bounds or bounds();assert(range[1]>=0 and range[2]<=R.GetProjectLength(0)+.001,'Mix bounds must be within the song.')
  assert(range[2]-range[1]>=3,'Choose at least three seconds of recorded audio.')
  assert(range[2]-range[1]<=600,'Choose an excerpt up to ten minutes long.')
  local id=R.genGuid():gsub('[^%w]','');local path=data..'/sessions/'..id
  R.RecursiveCreateDirectory(path,0);session=B.begin(path,range);handled='';chat_scroll=0
  save_config();local job={model=config.model,direction=config.direction,rounds=config.rounds,
   stop_after_usd=config.stop_after_usd,references=selected,bounds=range,visual_analysis=config.visual_analysis,target_lufs=config.target_lufs}
  for _,key in ipairs({'model','direction','rounds','stop_after_usd','references','visual_analysis','target_lufs'})do if options[key]~=nil then job[key]=options[key]end end
  J.write(path..'/config.json',job)
  state={state='running',events=J.array(),measurements=J.array(),updated=os.time()};phase='session'
  J.write(path..'/status.json',state);B.trace(session,'start_requested',{source=options.source or 'panel',config=job})
  local ok,err=pcall(launch,{'--session',path});if not ok then state.state='error';error(err)end
  status='Mixing the selected passage. Leave transport stopped until the candidate is ready.'
 end
 local function refs_menu()
  lib=read(data..'/library.json',lib);local choices={'No reference — natural balance'}
  for _,row in ipairs(lib.references)do
   local chosen=false;for _,id in ipairs(selected)do if id==row.id then chosen=true end end
   choices[#choices+1]=(chosen and '!'or '')..row.title:gsub('[|#!<>]',' ')
  end
  local n=gfx.showmenu(table.concat(choices,'|'))
  if n==1 then selected=J.array()elseif n>1 then
   local id=lib.references[n-1].id;local nextids=J.array();local found=false
   for _,v in ipairs(selected)do if v==id then found=true else nextids[#nextids+1]=v end end
   if not found then assert(#nextids<2,'Choose up to two references. Deselect one first.');nextids[#nextids+1]=id end
   selected=nextids
  end
  save_config()
 end
 local function import_reference()
  local ok,path=R.GetUserFileNameForRead('','Choose a reference recording','')
  if ok then
   os.remove(data..'/import-result.json');importing=true;status='Analyzing the reference locally…'
   launch({'--reference',path,'--result',data..'/import-result.json'})
  end
 end
 local function advanced()
  local ok,value=R.GetUserInputs('Mix target and pass limits',3,'Maximum model rounds (1-100),Stop after reported cost USD,Loudness target LUFS (-24 to -8),extrawidth=220',config.rounds..','..config.stop_after_usd..','..config.target_lufs)
  if ok then
   local rounds,cost,target=value:match('^([^,]+),([^,]+),([^,]+)$');rounds=tonumber(rounds);cost=tonumber(cost);target=tonumber(target)
   assert(rounds and rounds%1==0 and rounds>=1 and rounds<=100,'Rounds must be 1–100.')
   assert(cost and cost>0 and cost<=20,'Reported cost threshold must be above 0 and at most $20.')
   assert(target and target>=-24 and target<=-8,'Loudness target must be -24 to -8 LUFS. Quieter references can lower it further.')
   config.rounds=rounds;config.stop_after_usd=cost;config.target_lufs=target;save_config()
  end
 end
 local function choose_model()
  gfx.x=model_x;gfx.y=model_y
  local id=models.menu(config.model)
  if id then config.model=id;save_config();status='Mix model: '..models.selected(id).name end
 end
 local function wrap(value,width)
  gfx.setfont(3);local lines={};local line=''
  for paragraph in (value..'\n'):gmatch('(.-)\n')do
   for word in paragraph:gmatch('%S+')do
    local candidate=line==''and word or line..' '..word
    if gfx.measurestr(candidate)>width and line~=''then lines[#lines+1]=line;line=word else line=candidate end
   end
   lines[#lines+1]=line;line=''
  end
  return lines
 end
 local function metric(value)return type(value)=='number'and string.format('%.1f',value)or '—'end
 local function resume(value,options)
  assert(not X.busy()and state,'Wait for the current pass before giving feedback.')
  assert(not worker_active(),'The previous worker is still stopping. Wait before continuing.')
  local guarded,reason=pcall(B.guard,session,true)
  if not guarded then B.trace(session,'resume_rejected',{message=tostring(reason),context=B.diagnostics(session)});error(reason,0)end
  assert(session.mode=='candidate','Select Candidate first.')
  local job=read(session.path..'/config.json');job.resume=true
  job.direction=job.direction..'\nUser feedback: '..value
  job.rounds=config.rounds;job.stop_after_usd=config.stop_after_usd;job.target_lufs=config.target_lufs
  for _,key in ipairs({'rounds','stop_after_usd','model','visual_analysis','target_lufs'})do if options and options[key]~=nil then job[key]=options[key]end end
  J.write(session.path..'/config.json',job)
  -- A reopened panel has no in-memory handled ID. Retire the previous pass's
  -- final request before publishing running, so it cannot replay during spawn.
  local previous_request=read(session.path..'/request.json')
  handled=previous_request and previous_request.id or ''
  os.remove(session.path..'/cancel')
  os.remove(session.path..'/panel-stop.json')
  B.trace(session,'resume_requested',{feedback=value,source=options and options.source or 'panel'})
  state.events[#state.events+1]={role='user',text=value};state.state='running';state.updated=os.time();J.write(session.path..'/status.json',state)
  local ok,err=pcall(launch,{'--session',session.path});if not ok then state.state='error';error(err)end
  status='Continuing the candidate with a fresh pass budget.'
 end
 local function refine()
  assert(not X.busy()and state,'Wait for the current pass before giving feedback.')
  B.guard(session,true);assert(session.mode=='candidate','Select Candidate first.')
  local ok,value=R.GetUserInputs('Refine this candidate',1,'Your feedback:,extrawidth=350','')
  if ok and value~=''then resume(value)end
 end
 local function continue_mix()
  resume('Continue from this candidate. Inspect and reuse session-owned effects, measure the current result, and address the remaining reference, balance and output-peak gaps. Finish when the measured result is ready for audition.')
 end
 function X.control_status()
  return {session_id=session and session.path:match('([^/]+)$'),state=state and state.state,
   busy=X.busy()or false,pending=X.pending()or false,mode=session and session.mode,
   recovery_changed=session and session.recovery_changed or false,
   connected=connection().connected,defaults={model=config.model,direction=config.direction,rounds=config.rounds,
    stop_after_usd=config.stop_after_usd,visual_analysis=config.visual_analysis,references=selected,target_lufs=config.target_lufs},bounds=bounds()}
 end
 function X.control(command,args)
  args=args or {}
  if command=='start_mix'then start(args)
  else
   assert(session and args.session_id==session.path:match('([^/]+)$'),'This is not the active mix session.')
   if command=='resume_mix'then resume(args.feedback or 'Continue from this candidate; inspect the logs and address remaining measured mix issues.',args)
   elseif command=='cancel_mix'then
    assert(X.busy(),'No mixing pass is running.');cancelled()
    B.trace(session,'cancel_requested',{source='mcp'});status='Cancellation requested; waiting for the worker to stop. Candidate preserved.'
   else error('Unknown mix control')end
  end
  mix_view='ai';return X.control_status()
 end
 function X.draw(x,y,w,h)
  X.poll();text('Mix',x,y,2)
  button('AI mix',x+w-234,y,100,32,function()if library then library.stop()end;mix_view='ai';R.SetExtState(M.ns,'mix_view','ai',true)end,mix_view=='ai'and C.blue or nil)
  button('Bounces',x+w-123,y,123,32,function()mix_view='bounces';R.SetExtState(M.ns,'mix_view','bounces',true)end,mix_view=='bounces'and C.blue or nil)
  if mix_view=='bounces'then bounces().draw(x,y+48,w,h-48);return end
  text(status,x+80,y+7,3,C.muted,w-325)
  if phase=='intro'then
   text('Shape a mix from your recordings.',x,y+64,4)
   text('A measured first pass with faders, panning, effects and section automation.',x,y+103,1,C.muted)
   text('Compare the original and candidate before you keep any changes.',x,y+132,1,C.muted)
   button('Mix with AI',x,y+181,176,43,function()phase='setup'end,C.blue,not X.pending())
   text('Enter: configure mix  /  Local analysis + OpenRouter decisions',x,y+249,3,C.muted)
   text('Audio stays on this Mac. Track names, settings, direction, measurements and enabled analysis images go to your provider.',x,y+275,3,C.muted,w)
  elseif phase=='recovery'then
   text('Continue from your current mix',x,y+64,4)
   text('Tracks, levels, or effects changed after the last AI pass. Its comparison is now out of date.',x,y+103,1,C.muted,w)
   text('Start a new mix keeps everything exactly as it sounds now, including your manual edits.',x,y+139,1,C.muted,w)
   text('The previous pass\'s snapshots and analysis stay saved on this Mac.',x,y+175,3,C.muted,w)
   button('Start a new mix',x,y+218,190,43,restart,C.blue,R.GetPlayState()==0)
   button('Revert previous pass',x+203,y+218,190,43,function()finish(true)end,nil,R.GetPlayState()&4==0)
   text('Revert removes that pass\'s added effects and restores its unchanged faders; manual level/pan edits stay.',x,y+286,3,C.muted,w)
   text('Enter: start a new mix from the current sound. Stop playback first.',x,y+322,3,C.muted,w)
  elseif phase=='setup'then
   models.ensure()
   local c=connection();local right=x+w-350
   text('Reference',x,y+57,4)
   local names={};for _,row in ipairs(lib.references)do for _,id in ipairs(selected)do if row.id==id then names[#names+1]=row.title end end end
   text(#names>0 and table.concat(names,' + ')or 'Natural balance · no reference',x,y+88,3,C.muted,w-380)
   button('Choose references',x,y+116,165,33,refs_menu)
   button(importing and 'Analyzing…'or 'Analyze new…',x+175,y+116,143,33,import_reference,nil,not importing)
   button('Set as default',x+328,y+116,139,33,function()lib.default=selected[1]or '';J.write(data..'/library.json',lib);status='Default reference saved.'end)
   text('Mix direction',x,y+174,4)
   text(config.direction,x,y+207,3,C.muted,w-400)
   button('Edit direction…',x,y+235,160,33,function()
    local ok,value=R.GetUserInputs('Mix direction',1,'Describe the sound:,extrawidth=350',config.direction)
    if ok then config.direction=value;save_config()end
   end)
   local range=bounds()
   button(full_song and 'Scope: full song'or 'Scope: time selection',x+170,y+235,222,33,function()full_song=not full_song end)
   text(string.format('%.1f – %.1f sec',range[1],range[2]),x+405,y+244,3,C.muted)
   text('OpenRouter',right,y+57,4)
   text(checking and 'Checking connection…'or (c.connected and 'Connected · analysis ready'or 'Connection required'),right,y+88,3,c.connected and C.blue or C.gold)
   button('Connect / change key',right,y+116,178,33,function()R.ExecProcess('/usr/bin/open '..quote(worker_dir..'/Connect OpenRouter.command'),-1);status='Enter the key in Terminal, then Refresh connection here.'end)
   button('Refresh connection',right+186,y+116,164,33,function()os.remove(data..'/connection.json');checking=true;launch({'--check',data..'/connection.json'})end,nil,not checking)
   text('AI model',right,y+163,4)
   model_x,model_y=right,y+228
   button(models.selected(config.model).name..'  ▾',right,y+193,350,35,choose_model)
   text(models.price(config.model),right,y+240,3,C.muted,350)
   button(models.busy and 'Refreshing…'or 'Refresh models',right,y+272,167,30,models.refresh,nil,not models.busy)
   button('Advanced settings…',right+175,y+272,175,30,advanced)
   if models.message()then text('Offline list · retry Refresh models',right,y+315,3,C.gold,350)end
   text('Target: '..metric(config.target_lufs)..' LUFS or a quieter reference. Advanced settings changes the target and pass limits.',x,y+301,3,C.muted,w)
   button('Create candidate mix',x,y+333,215,40,start,C.blue,c.connected and not importing and not X.pending()and R.GetPlayState()==0)
   button('Back',x+227,y+333,87,40,function()phase='intro'end)
   button(config.visual_analysis and 'Visual analysis: on'or 'Visual analysis: off',x+326,y+333,196,40,function()
    config.visual_analysis=not config.visual_analysis;save_config()
    status=config.visual_analysis and 'Send measured charts when the selected model supports images.'or 'Use numerical measurements only.'
   end,config.visual_analysis and C.blue or nil)
  else
   local busy=X.busy();local measurements=state and state.measurements or {};local first=measurements[1];local last=measurements[#measurements]
   local label=busy and 'Working · leave transport stopped'or 'Review the candidate'
   text(label,x,y+52,4)
   if first then
    text('Original: '..metric(first.loudness.integrated_lufs)..' LUFS  /  '..metric(first.loudness.true_peak_dbtp)..' dBTP',x+355,y+58,3,C.muted)
    if type(state.measurement_error)=='table'and type(state.measurement_error.reason)=='string'then text('Candidate: unverified (render failed)',x+730,y+58,3,C.gold)
    elseif last and #measurements>1 then text('Candidate: '..metric(last.loudness.integrated_lufs)..' LUFS  /  '..metric(last.loudness.true_peak_dbtp)..' dBTP',x+730,y+58,3,C.blue)end
   end
   local transport=R.GetPlayState();local stopped=transport==0;local reviewing=not busy and transport&4==0
   button('Original',x,y+85,105,32,function()B.compare(session,'original')end,session.mode=='original'and C.blue or nil,reviewing)
   button('Candidate',x+114,y+85,110,32,function()B.compare(session,'candidate')end,session.mode=='candidate'and C.blue or nil,reviewing)
   button('Keep mix',x+235,y+85,104,32,function()finish(false)end,nil,reviewing and state and state.state=='review'and session.mode=='candidate')
   button(busy and 'Cancel & revert'or 'Revert',x+350,y+85,148,32,function()finish(true)end,nil,reviewing or stopped)
   button('Show analysis files',x+510,y+85,169,32,function()R.ExecProcess('/usr/bin/open '..quote(session.path),-1)end)
   button('Give feedback…',x+690,y+85,155,32,refine,nil,not busy and stopped and state~=nil)
   text('A/B at actual levels.  1: Original  /  2: Candidate  /  Space: play or stop',x,y+126,3,C.muted,680)
   button('Continue mixing',x+690,y+121,155,27,continue_mix,nil,not busy and stopped and state~=nil and session.mode=='candidate')
   button('Target '..metric(config.target_lufs)..' LUFS · Limits…',x+855,y+121,233,27,advanced,nil,not busy)
   button(show_graphs and 'Chat log'or 'Graphs',x+855,y+85,105,32,function()show_graphs=not show_graphs end,nil,#measurements>1)
   button('New mix…',x+970,y+85,118,32,restart,nil,not busy and stopped)
   if show_graphs and #measurements>1 then
    for i,tab in ipairs({{'overview','Overview'},{'spectrogram','Spectrogram'},{'waterfall','Waterfall'},{'dynamics','Dynamics'}})do
     button(tab[2],x+(i-1)*132,y+154,122,29,function()graph_mode=tab[1]end,graph_mode==tab[1]and C.blue or nil)
    end
    if graph_mode~='overview'then
     local filename=graphics and graphics.views and graphics.views[graph_mode]
     if filename and not filename:match('^[%w_.%-]+%.png$')then filename=nil end
     local path=filename and session.path..'/visuals/'..filename
     if path then
      button('Open full size',x+540,y+154,137,29,function()R.ExecProcess('/usr/bin/open '..quote(path),-1)end)
      if graph_image~=path then
       gfx.setimgdim(graph_slot,0,0)
       if gfx.loadimg(graph_slot,path)>=0 then graph_image=path else graph_image=nil end
      end
      if graph_image then
       local iw,ih=gfx.getimgdim(graph_slot);local scale=math.min(w/iw,math.max(1,h-236)/ih)
       gfx.x=x+(w-iw*scale)/2;gfx.y=y+194;gfx.a=1;gfx.blit(graph_slot,scale,0)
       text('Last measured audio · '..(graphics.title or 'Candidate')..' · Charts do not change with live playback or A/B.',x,y+h-24,3,C.muted,w)
      else text('Chart could not be loaded. Use Open full size or Show analysis files.',x,y+215,3,C.gold,w)end
     else
      text(graphics_working and 'Building graphics from the saved audio…'or 'Create these views from the last measured full mix.',x,y+210,3,C.muted,w)
      button(graphics_working and 'Generating…'or 'Generate graphics',x,y+252,190,35,function()
       os.remove(session.path..'/graphics-status.json');graphics_working=true
       launch({'--graphics',session.path})
      end,nil,not busy and not graphics_working)
      text('Uses the saved render. No new REAPER render or AI request.',x,y+303,3,C.muted,w)
     end
     return
    end
    local plots={{x=x,y=y+217,w=(w-45)/2,h=h-270},{x=x+(w+25)/2,y=y+217,w=(w-45)/2,h=h-270}}
    local curves={{p=first,c=C.muted},{p=last,c=C.blue}}
    for _,ref in ipairs(lib.references)do for _,id in ipairs(selected)do if id==ref.id then
     local profile=read(ref.profile);if profile then curves[#curves+1]={p=profile,c=#curves==2 and C.gold or {0.73,0.52,0.78}}end
    end end end
    text('Spectrum · relative band energy',plots[1].x,y+191,3,C.text)
    text('Level envelope · RMS dBFS',plots[2].x,y+191,3,C.text)
    for n,plot in ipairs(plots)do
     color(C.surface);gfx.rect(plot.x,plot.y,plot.w,plot.h,1)
     for i=0,3 do color(C.line);gfx.line(plot.x,plot.y+plot.h*i/3,plot.x+plot.w,plot.y+plot.h*i/3)end
     for index,curve in ipairs(curves)do
      if n==1 or index<=2 then
       local previous;local points=n==1 and curve.p.spectrum or curve.p.envelope_1s
       for _,point in ipairs(points or {})do
        local value=n==1 and point.relative_db or point.rms_dbfs
        if type(value)=='number'then
         local px=n==1 and math.log(math.sqrt(point.low_hz*point.high_hz)/20)/math.log(1000)or point.seconds/math.max(1,curve.p.duration_seconds)
         local py=1+math.max(-60,math.min(0,value))/60
         local xx,yy=plot.x+px*plot.w,plot.y+plot.h*(1-py)
         if previous then color(curve.c);gfx.line(previous[1],previous[2],xx,yy)end;previous={xx,yy}
        end
       end
      end
     end
    end
    text('20 Hz                                             20 kHz',plots[1].x,y+h-40,3,C.muted)
    text('Start                                              End',plots[2].x,y+h-40,3,C.muted)
    text('Gray: original    Blue: candidate    Gold / purple: references    Scale: 0 to -60 dB',x,y+h-18,3,C.muted,w)
    return
   end
   local lines={}
   for _,event in ipairs(state and state.events or {})do
    local prefix=event.role=='user'and 'YOU  'or (event.role=='assistant'and 'MIX ASSISTANT  'or (event.role=='tool'and 'ACTION  'or ''))
    for _,line in ipairs(wrap(prefix..event.text,w-35))do lines[#lines+1]=line end
    lines[#lines+1]=''
   end
   local visible=math.max(3,math.floor((h-184)/20));local maxscroll=math.max(0,#lines-visible)
   chat_scroll=math.max(0,math.min(chat_scroll,maxscroll));local start=math.max(1,#lines-visible+1-chat_scroll)
   color(C.surface);gfx.rect(x,y+155,w,h-160,1)
   for i=start,math.min(#lines,start+visible-1)do text(lines[i],x+12,y+166+(i-start)*20,3,C.text,w-25)end
  end
 end
 function X.key(ch)
  if ch==108 or ch==76 then
   mix_view=mix_view=='ai'and 'bounces'or 'ai';if library then library.stop()end
   R.SetExtState(M.ns,'mix_view',mix_view,true);return true
  end
  if mix_view=='bounces'then return bounces().key(ch)end
  if ch==13 and phase=='recovery'then if R.GetPlayState()==0 then ui.run(restart)end;return true end
  if phase=='session'and (ch==103 or ch==71)then ui.run(refine);return true end
  if phase=='session'and (ch==49 or ch==50)then
   if not X.busy()and R.GetPlayState()&4==0 then ui.run(function()B.compare(session,ch==49 and 'original'or 'candidate')end)end
   return true
  end
  if ch==13 and phase=='intro'then if not X.pending()then phase='setup'end;return true end
  if phase=='setup'and (ch==111 or ch==79)then ui.run(choose_model);return true end
  return false
 end
 function X.wheel(delta)if mix_view=='bounces'then bounces().wheel(delta)else chat_scroll=math.max(0,chat_scroll+delta*3)end end
 function X.close(reason)
  if graph_image then gfx.setimgdim(graph_slot,0,0);graph_image=nil end
  if library then library.close()end
  if session and not session.finished then
   if X.busy()then stopped(reason or 'panel_closed','Mix stopped because '..(reason=='project_switched'and 'the active project changed.'or 'the Solo Studio panel closed.'))end
   cancelled()
   -- Closing/reloading the panel must not silently undo the user's mix.
   -- The journal reopens review (or offers a fresh pass if the project changed).
  end
 end
 return X
end
