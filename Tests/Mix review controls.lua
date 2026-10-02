-- Exercise the native panel's real draw/key handlers without a GUI or network worker.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local state,transport,session,compared,kept,reverted,buttons,archived,foreign,extstate
local settings,writes,launches,input,job,legacy,measurement_error,measurements,labels
local graph_manifest,reference_manifest,track_manifest,loaded_image,graph_test_project,graph_capture_result,graph_operations,last_launch
local poll_clock,bridge_request,bridge_calls=0,nil,0
local J={array=function(t)return t or {}end,write=function(path,value)writes[path]=value end}
function J.read(path)
 if path:match('/status.json$')then return {state=state,events={},measurements=measurements or {},measurement_error=measurement_error}end
 if path:match('/settings.json$')then return settings or {}end
 if path:match('/config.json$')then return job end
 if path:match('/library.json$')then return {references={},default=''}end
 if path:match('/snapshot.json$')then return {finished=false,project_path='other.rpp'}end
 if path:match('/connection.json$')then return {connected=true}end
 if path:match('/graphics.json$')then return graph_manifest end
 if path:match('/reference%-graphics.json$')then return reference_manifest end
 if path:match('/track%-graphics.json$')then return track_manifest end
 if path:match('/request.json$')then return bridge_request end
end
local B={json=J,find_session=function()return not foreign and session or nil end,
 trace=function()end,diagnostics=function()return {transport=transport}end,
 execute=function(_,name,args)
  bridge_calls=bridge_calls+1
  if graph_operations then graph_operations[#graph_operations+1]={name=name,args=args}end
  if name=='inspect_project'and graph_test_project then return graph_test_project end
  if name=='measure_track'and graph_capture_result then return graph_capture_result end
  return {}
 end,
 guard=function()assert(transport==0,'Stop transport')end,
 compare=function(_,mode)compared=mode;session.mode=mode end,
 keep=function()kept=true;session.finished=true end,
 revert=function()reverted=true;session.finished=true;return 0 end,
 archive_current=function()assert(transport==0);archived=true;session.finished=true end}
local original_dofile=dofile
function dofile(path)
 if path:match('/solo_mix_bridge.lua$')then return B end
 if path:match('/solo_models.lua$')then return {default='test',new=function()return {
  poll=function()end,ensure=function()end,selected=function()return {name='test'}end,
  price=function()return 'test'end,message=function()end}end}end
 return original_dofile(path)
end
reaper={RecursiveCreateDirectory=function()end,GetExtState=function(_,key)return key=='mix_session'and legacy or ''end,
 GetPlayState=function()return transport end,time_precise=function()return poll_clock end,
 GetSet_LoopTimeRange2=function()return 0,20 end,SetExtState=function(_,_,v)extstate=v end,
 GetUserInputs=function()return true,input end,ExecProcess=function(command)last_launch=command;launches=launches+1;return ''end}
gfx={setfont=function()end,rect=function()end,measurestr=function(v)return #v*7 end,
 setimgdim=function()end,loadimg=function(_,path)loaded_image=path;return 701 end,
 getimgdim=function()return 1200,600 end,blit=function()end}
local factory=original_dofile(root..'/Scripts/solo_mix.lua')
local ui={text=function(label)labels[label]=true end,color=function()end,colors={},run=function(fn)fn()end,
 button=function(label,x,y,w,h,fn,color,enabled)buttons[label]={run=fn,enabled=enabled~=false}end}
local function panel(t,status,mode,changed,other_project)
 transport=t;state=status or 'review';session={path='/nonexistent-test-mix',mode=mode or 'candidate',recovery_changed=changed}
 compared=nil;kept=false;reverted=false;archived=false;foreign=other_project;extstate=nil;buttons={};labels={}
 writes={};launches=0;job={direction='Original direction',rounds=20,stop_after_usd=2};poll_clock=0;bridge_request=nil;bridge_calls=0
 legacy=other_project and '/other-project-mix'or session.path
 local x=factory({ns='test'},ui);x.draw(0,0,1200,700);return x
end
for _,t in ipairs({0,1,2,3})do
 local x=panel(t)
 check(buttons.Original.enabled and buttons.Candidate.enabled,'A/B enabled in transport '..t)
 check(buttons['Keep mix'].enabled and buttons.Revert.enabled,'Keep/revert enabled in transport '..t)
 check(buttons['Give feedback…'].enabled==(t==0),'Refinement requires stopped transport '..t)
 check(buttons['Continue mixing'].enabled==(t==0),'Continue requires stopped transport '..t)
 check(x.key(49)and compared=='original'and x.key(50)and compared=='candidate','Keyboard A/B works in transport '..t)
end
for _,t in ipairs({4,5,6,7})do
 local x=panel(t)
 check(not buttons.Original.enabled and not buttons.Candidate.enabled and not buttons['Keep mix'].enabled and not buttons.Revert.enabled,'Review disabled while recording '..t)
 x.key(49);x.key(50);check(compared==nil,'Keyboard cannot bypass recording lock '..t)
end
panel(1,'review_warning');check(not buttons['Keep mix'].enabled and buttons.Original.enabled,'Peak warning still prevents Keep after recovery')
measurement_error={reason='silent_or_unmeasurable'};measurements={{loudness={integrated_lufs=-16,true_peak_dbtp=-2}},{loudness={integrated_lufs=-14,true_peak_dbtp=-1}}}
panel(0,'error');check(labels['Candidate: unverified (render failed)'] and not labels['Candidate: -14 LUFS  /  -1 dBTP'],'Failed render hides outdated candidate metrics')
check(not buttons['Keep mix'].enabled and buttons.Original.enabled and buttons.Revert.enabled,'Silent render keeps A/B and Revert available without accepting an unmeasured mix')
measurement_error={};panel(0,'review')
check(labels['Candidate: -14.0 LUFS  /  -1.0 dBTP'] and not labels['Candidate: unverified (render failed)'],'Decoded JSON null cannot masquerade as a failed render')
measurement_error=nil;measurements=nil
panel(1,'running');check(not buttons['Keep mix'].enabled,'Interrupted worker recovers without accepting incomplete mix')
panel(0,'cancelled');check(buttons['Give feedback…'].enabled and not buttons['Keep mix'].enabled,'Interrupted pass can continue from feedback without accepting unmeasured changes')
panel(1,'review','original');check(not buttons['Keep mix'].enabled and buttons.Candidate.enabled,'Recovered Original can switch back but cannot be kept')
panel(0,'review','original');check(not buttons['Continue mixing'].enabled,'Continue requires Candidate')
local resumed=panel(0,'review_warning');input='80,2,-14';buttons['Target -12.0 LUFS · Limits…'].run()
bridge_request={id='old-worker-99',name='add_effect',arguments={}}
buttons['Continue mixing'].run()
check(launches==1 and job.resume and job.rounds==80 and job.stop_after_usd==2,'Continue uses latest limits instead of the old twenty-round job')
check(job.target_lufs==-14,'Changed loudness target applies to continuation')
check(not archived and not kept and not reverted and resumed.pending(),'Continue preserves original comparison and session ownership')
check(job.feedback:find('reuse session%-owned effects')~=nil,'Continuation asks to reuse owned effects')
state='running';poll_clock=1;resumed.poll()
check(bridge_calls==0,'Recovered continuation cannot replay the old worker final effect edit')
bridge_request={id='new-worker-1',name='inspect_project',arguments={}};poll_clock=2;resumed.poll()
check(bridge_calls==1,'New worker requests are still processed after retiring the old request')
settings={rounds=7,stop_after_usd=1};panel(0);input='Lift vocals';buttons['Give feedback…'].run()
check(job.rounds==7 and job.stop_after_usd==1 and job.feedback=='Lift vocals','Feedback preserves explicitly configured smaller budgets')
job.direction='Natural indie rock\nUser feedback: Apply leveling again\nUser feedback: Add brightness'
state='review';panel(0);job.direction='Natural indie rock\nUser feedback: Apply leveling again'
input='Reduce limiting only';buttons['Give feedback…'].run()
check(job.direction=='Natural indie rock'and job.feedback=='Reduce limiting only','Current feedback replaces old instructions without repeating completed tasks')
settings=nil
panel(0);input='60,2,-6';check(not pcall(buttons['Target -12.0 LUFS · Limits…'].run),'Over-loud target rejected before settings change')
check(next(writes)==nil,'Rejected loudness target does not change saved settings')
measurements={{loudness={integrated_lufs=-16,true_peak_dbtp=-2}},{loudness={integrated_lufs=-12,true_peak_dbtp=-1}}}
local graph_panel=panel(0);buttons.Graphs.run();graph_panel.draw(0,0,1200,700)
check(buttons.Spectrogram and buttons.Waterfall and buttons.Dynamics and buttons.Overview,'Measured graph view exposes all four chart tabs')
check(buttons['Generate graphics'].enabled,'Legacy review can generate plots from saved renders')
buttons['Generate graphics'].run();check(launches==1,'Generating graphics launches a local background job')
check(not kept and not reverted and not compared,'Graph generation cannot change the candidate')
graph_panel=panel(0);check(graph_panel.key(118),'V opens measured graphics from the keyboard')
buttons={};graph_panel.draw(0,0,1200,700)
check(buttons['Chat log']and buttons.Spectrogram,'Keyboard graphics use the same graph view')
graph_manifest={render='render-1-test.wav',views={spectrogram='mix.png'}}
reference_manifest={render='render-1-test.wav',references={{title='Reference',views={spectrogram='reference.png'},comparison='comparison.png'}}}
poll_clock=1;graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/mix.png$'),'Current mix uses its own graph')
graph_panel.key(98);graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/reference.png$'),'B selects the reference graph')
graph_panel.key(98);graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/comparison.png$'),'B selects the loudness-matched comparison')
graph_manifest.render='render-2-test.wav';poll_clock=2;graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/mix.png$'),'A new render cannot display stale reference comparison')
track_manifest={tracks={{key='{A}:full',track='{A}',name='Guitar',bounds={0,20},measured_at=100,views={spectrogram='guitar.png'}}}}
poll_clock=3;graph_panel.draw(0,0,1200,700);graph_panel.key(98);graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/guitar.png$'),'Track spectrogram is selectable independently of reference/mix graphs')
graph_panel.key(98);graph_panel.draw(0,0,1200,700)
check(loaded_image:match('/mix.png$'),'Source cycling returns from the track to the mix')
track_manifest=nil
graph_test_project={tracks={{id='{A}',name='Guitar'},{id='{B}',name='Guitar'}}}
graph_capture_result={path='/nonexistent-test-mix/render-1-test.wav',bounds={0,20},scope='Solo-in-place including master FX'}
gfx.showmenu=function()return 2 end
graph_panel=panel(0);graph_panel.key(118);graph_operations={};graph_panel.key(116)
local capture=writes['/nonexistent-test-mix/track-graphics-request.json']
check(capture.track=='{B}'and capture.render=='render-1-test.wav','Track render uses selected GUID even when names match')
check(#graph_operations==2 and graph_operations[1].name=='inspect_project'and graph_operations[2].name=='measure_track','Manual graph render has no mixing edits')
check(last_launch:find('%-%-track%-capture')and not graph_panel.busy(),'Track analysis runs locally without starting an AI mixing pass')
for _,t in ipairs({1,4,5})do
 graph_panel=panel(t);graph_panel.key(118);graph_operations={};graph_panel.key(116)
 check(#graph_operations==0,'Track rendering cannot interrupt transport '..t)
end
graph_panel=panel(0,'review','original');graph_panel.key(118);graph_operations={};graph_panel.key(116)
check(#graph_operations==0,'Track rendering cannot silently switch Original to Candidate')
graph_test_project=nil;graph_capture_result=nil;graph_operations=nil
graph_manifest=nil;reference_manifest=nil
measurements=nil
local x=panel(0,'review','candidate',true)
check(buttons['Start a new mix'].enabled and not buttons.Original,'Changed project offers current-mix recovery instead of outdated A/B')
x.key(49);x.key(50);check(not compared,'Recovery page cannot trigger hidden A/B shortcuts')
-- Allow the cancellation marker to be created in a disposable location.
local tmp=os.tmpname();os.remove(tmp);assert(os.execute('mkdir -p "'..tmp..'"'));session.path=tmp;legacy=tmp
buttons['Start a new mix'].run();buttons={};x.draw(0,0,1200,700)
check(archived and not reverted and not kept and extstate==''and not x.pending(),'Fresh start clears the blocker without accepting or reverting the old candidate')
check(buttons['Create candidate mix'].enabled,'Fresh start opens configured setup without launching a worker')
for _,t in ipairs({1,4,5})do
 x=panel(t,'review','candidate',true);x.key(13)
 check(not buttons['Start a new mix'].enabled and not archived,'Fresh start and Enter wait for stopped transport '..t)
end
x=panel(0,'review','candidate',true);session.path=tmp;legacy=tmp;x.key(13)
check(archived and not x.pending(),'Enter opens fresh setup from recovery while stopped')
x=panel(0);session.path=tmp;x.close();check(not reverted and not kept and extstate==nil and x.pending(),'Panel close preserves unfinished mix for explicit review')
x=panel(0,'review','candidate',false,true);check(buttons['Mix with AI'].enabled and not x.pending(),'Another song unfinished mix does not block this project')
x.key(13);buttons={};x.draw(0,0,1200,700)
check(buttons['Create candidate mix'].enabled and not reverted and not kept and extstate==nil,'New project opens setup without touching another song mix')
x=panel(0);session.path=tmp;legacy='/other-project-mix';buttons.Revert.run()
check(reverted and extstate==nil,'Reverting this song leaves another song legacy pointer intact')
os.remove(tmp..'/cancel');os.remove(tmp)
print(passed..' mix review controls checks passed')
