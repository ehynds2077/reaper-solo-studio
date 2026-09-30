-- Real core, track manager, and Tracks view against a small project fixture.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={tracks={},state={},revision=0,project='song',recording=false,edits=0,buttons={},labels={},confirm=7,sliders={}}
 local function add(key,name,depth,items)
  local tr={key=key,name=name,delta=depth,items=items or 0,fx=2,input=0,volume=1,mute=0,pan=0,pan_mode=3,pan_left=-1,pan_right=1,width=1,props={}};f.tracks[#f.tracks+1]=tr;return tr
 end
 f.folder=add('folder','Drums',1);f.kick=add('kick','Kick',0,6);f.inner=add('oh','Overheads',1)
 f.left=add('left','OH L',0,6);f.right=add('right','OH R',-2,6);f.guitar=add('guitar','Guitar',0,2)
 f.state={sets='drums\nguitar',active='drums',['set.drums.tracks']='kick\nleft\nright',['set.drums.name']='Drums',
  ['set.guitar.tracks']='guitar',['set.guitar.name']='Guitar'}
 reaper={
  CountTracks=function()return #f.tracks end,GetTrack=function(_,i)return f.tracks[i+1]end,
  GetTrackGUID=function(tr)return tr.key end,CountTrackMediaItems=function(tr)return tr.items end,
  TrackFX_GetCount=function(tr)return tr.fx end,IsTrackSelected=function(tr)return tr.selected or false end,
  GetMediaTrackInfo_Value=function(tr,key)
   local field=({I_FOLDERDEPTH='delta',I_RECINPUT='input',D_VOL='volume',B_MUTE='mute',D_PAN='pan',I_PANMODE='pan_mode',D_DUALPANL='pan_left',D_DUALPANR='pan_right',D_WIDTH='width'})[key]
   return field and tr[field]or 0
  end,
  SetMediaTrackInfo_Value=function(tr,key,value)
   if f.fail and f.fail.track==tr and f.fail.key==key then f.fail=nil;return false end
   local field=assert(({I_FOLDERDEPTH='delta',D_VOL='volume',B_MUTE='mute',D_PAN='pan',D_DUALPANL='pan_left',D_DUALPANR='pan_right'})[key]);tr[field]=value;f.revision=f.revision+1;return true
  end,
  GetSetMediaTrackInfo_String=function(tr,key,value,set)
   if key=='P_NAME'then if set then tr.name=value;f.revision=f.revision+1 end;return true,tr.name end
   if set then tr.props[key]=value;f.revision=f.revision+1 end;return (tr.props[key]or '')~='',tr.props[key]or ''
  end,
  GetTrackEnvelopeByChunkName=function(tr,key)return tr.envelopes and tr.envelopes[key]end,
  GetEnvelopeStateChunk=function(env)return true,'\nACT '..env.active..'\n'end,
  GetProjExtState=function(_,_,key)return 1,f.state[key]or ''end,SetProjExtState=function(_,_,key,value)f.state[key]=value end,
  EnumProjects=function()return f.project end,GetPlayState=function()return f.recording and 4 or 0 end,
  GetProjectStateChangeCount=function()return f.revision end,
  ValidatePtr2=function(_,tr)for _,candidate in ipairs(f.tracks)do if tr==candidate then return true end end;return false end,
  DeleteTrack=function(tr)for i,candidate in ipairs(f.tracks)do if candidate==tr then table.remove(f.tracks,i);f.revision=f.revision+1;return end end;error('Missing track')end,
  Undo_BeginBlock2=function()
   f.edits=f.edits+1;f.undo_state={}
   for _,tr in ipairs(f.tracks)do
    local props={};for k,v in pairs(tr.props)do props[k]=v end
    f.undo_state[#f.undo_state+1]={track=tr,name=tr.name,volume=tr.volume,mute=tr.mute,pan=tr.pan,pan_left=tr.pan_left,pan_right=tr.pan_right,props=props}
   end
  end,Undo_EndBlock2=function()end,PreventUIRefresh=function()end,
  UpdateTimeline=function()end,TrackList_AdjustWindows=function()end,MarkProjectDirty=function()end,
  SetTrackSelected=function(tr,value)tr.selected=value end,
  GetUserInputs=function()return f.answer~=nil,f.answer end,
  ShowMessageBox=function(message)f.dialog=message;return f.confirm end,
 }
 local M=dofile(root..'/Scripts/solo_core.lua');local T=dofile(root..'/Scripts/solo_tracks.lua')(M,{busy=function()return f.busy end})
 f.M,f.T=M,T
 gfx={mouse_x=0,mouse_y=0,rect=function()end}
 local V=dofile(root..'/Scripts/solo_tracks_view.lua')(M,{colors={muted={},text={},surface={},record={},blue={},gold={}},busy=function()return f.busy end,
  text=function(label)f.labels[#f.labels+1]=label end,color=function()end,
  button=function(label,x,y,w,h,fn,_,enabled)f.labels[#f.labels+1]=label;if enabled~=false then f.buttons[#f.buttons+1]={label=label,y=y,fn=fn}end end,
  slider=function(id,x,y,w,value,fn,enabled)if enabled then f.sliders[#f.sliders+1]={id=id,value=value,fn=fn}end end,
  hit=function(_,_,_,_,fn,enabled)if enabled then f.select=fn end end,
  changed=function(message)f.message=message end})
 function f.draw()f.buttons={};f.labels={};f.sliders={};V.draw(24,215,1152,680,f.recording)end
 function f.click(label,index)local n=0;for _,b in ipairs(f.buttons)do if b.label==label then n=n+1;if n==(index or 1)then b.fn();return true end end end;return false end
 function f.undo()
  for _,saved in ipairs(f.undo_state)do for _,key in ipairs({'name','volume','mute','pan','pan_left','pan_right','props'})do saved.track[key]=saved[key]end end
  f.revision=f.revision+1
 end
 f.V=V;return f
end
local f=fixture();local rows=f.T.list()
check(#rows==6 and rows[5].depth==2 and rows[6].depth==0,'Tracks include nested folder indentation and the following outside track')
check(rows[2].sets[1].name=='Drums'and rows[2].items==6 and rows[2].input==0,'Tracks expose recording-set membership, items, and input')
f.T.rename('guitar','Double guitar',f.project)
check(f.guitar.name=='Double guitar'and f.M.sets()[2].name=='Double guitar'and f.edits==1,'Renaming a single track also labels its recording set in one native edit')
f.guitar.name='Guitar';check(f.M.sets()[2].name=='Guitar','Recording-set labels follow native name restoration without separate metadata')
check(not pcall(f.T.rename,'guitar','  ')and not pcall(f.T.rename,'guitar','a\nb'),'Empty and multiline names are rejected')
check(not pcall(f.T.rename,'guitar','Changed','other'),'Rename guards the project that opened the dialog')
f=fixture();local plan=f.T.plan_delete('right');f.T.delete(plan)
check(#f.tracks==5 and f.left.delta==-2 and f.T.list()[5].depth==0,'Deleting a folder-closing mic preserves nested folder boundaries')
check(#f.M.tracks()==2 and f.M.tracks()[1]==f.kick,'Deleting one microphone leaves the remaining recording set usable')
table.insert(f.tracks,5,f.right);f.left.delta=0
check(#f.M.tracks()==3 and f.M.tracks()[3]==f.right,'Restoring the native track GUID restores recording-set membership')
f=fixture();plan=f.T.plan_delete('oh')
check(#plan.rows==3 and plan.items==12 and plan.fx==6,'Folder deletion explicitly plans all child tracks, items, and effects')
f.T.delete(plan)
check(#f.tracks==3 and f.kick.delta==-1 and f.T.list()[3].depth==0,'Deleting an inner folder preserves its parent and the following guitar')
f=fixture();plan=f.T.plan_delete('folder');f.T.delete(plan)
check(#f.tracks==1 and f.tracks[1]==f.guitar and f.guitar.delta==0,'Deleting a whole folder leaves the following instrument intact')
check(#f.M.sets()==1 and f.M.get('active')=='guitar','Empty recording sets disappear and the next surviving set becomes available')
table.insert(f.tracks,1,f.kick)
check(#f.M.sets()==2 and f.M.get('active')=='drums','Restored tracks recover the original active set without rewriting its registry')
f=fixture();plan=f.T.plan_delete('guitar');f.project='different'
check(not pcall(f.T.delete,plan)and #f.tracks==6,'Switching projects invalidates a pending deletion')
f=fixture();plan=f.T.plan_delete('guitar');f.revision=f.revision+1
check(not pcall(f.T.delete,plan)and #f.tracks==6,'Changes during confirmation require a fresh deletion review')
f=fixture();plan=f.T.plan_delete('guitar');f.recording=true
check(not pcall(f.T.delete,plan)and not pcall(f.T.rename,'guitar','New')and #f.tracks==6,'Recording locks rename and deletion even through the backend')
f=fixture();f.draw();f.click('Delete...',1)
check(f.dialog:find('3 tracks',1,true)and f.dialog:find('18 audio/MIDI items',1,true),'Group delete confirmation lists its tracks and recordings')
check(#f.tracks==6 and f.edits==0,'Cancelling the confirmation leaves every track intact')
f.confirm=6;f.click('Delete...',1)
check(#f.tracks==3 and f.tracks[3]==f.guitar and f.message:find('Deleted 3 tracks',1,true),'Confirming group deletion removes only its reviewed members')
f=fixture();f.draw();f.click('+',1);f.draw();f.answer='Kick close';f.click('Rename...',2)
check(f.kick.name=='Kick close'and f.message:find('Track renamed',1,true),'The row Rename button changes the selected native track')
f=fixture();f.recording=true;f.draw()
check(not f.click('Rename...')and not f.click('Delete...'),'Tracks view disables destructive row actions during recording')
local function group(f,id)for _,row in ipairs(f.T.groups())do if row.id==id then return row end end end
local function near(a,b)return math.abs(a-b)<1e-9 end
local function labeled(f,name)for _,label in ipairs(f.labels)do if label==name then return true end end;return false end
f=fixture();f.draw()
check(labeled(f,'Track groups')and labeled(f,'Drums')and labeled(f,'Guitar')and not labeled(f,'Kick'),'Tracks initially shows collapsed instrument groups instead of microphone rows')
check(labeled(f,'Other tracks')and #f.T.groups()[3].members==2,'Folder buses and unassigned tracks remain reachable outside recording groups')
check(f.edits==0 and #f.sliders==4,'Drawing the grouped view only reads the existing mix')
f.click('+',1);f.draw();check(labeled(f,'Kick')and labeled(f,'OH L')and #f.sliders==10,'Expanding a group exposes each member and its own volume and pan controls')
f=fixture();f.draw();f.answer='Live drums';f.click('Rename...',1)
check(f.M.sets()[1].name=='Live drums'and f.kick.name=='Kick'and f.left.name=='OH L','Group rename updates the instrument label without renaming its microphones')
f.undo();check(f.M.sets()[1].name=='Drums','Restoring native track metadata restores the original group label')
f.T.rename_group(group(f,'drums'),'Kit',f.project);table.remove(f.tracks,2)
check(f.M.sets()[1].name=='Kit','The group name survives deletion of its first microphone')
f=fixture();f.kick.volume=1;f.left.volume=.5;f.right.volume=.25
local drums=group(f,'drums');f.T.set_volume(drums,-6,f.project);local gain=10^(-6/20)
check(near(f.kick.volume,gain)and near(f.left.volume,gain*.5)and near(f.right.volume,gain*.25)and f.guitar.volume==1,'Group volume preserves microphone ratios and leaves other instruments unchanged')
check(f.edits==1,'A group level change uses a single native Undo block')
f.undo();check(f.kick.volume==1 and f.left.volume==.5 and f.right.volume==.25,'Undo restores every member level together')
drums=group(f,'drums');f.left.volume=.4
check(not pcall(f.T.set_volume,drums,-3,f.project)and f.kick.volume==1,'An external fader change cancels a stale group-volume adjustment')
drums=group(f,'drums');f.project='other'
check(not pcall(f.T.set_volume,drums,-3,'song')and not pcall(f.T.rename_group,drums,'Wrong','song'),'A project switch invalidates pending group edits')
f=fixture();drums=group(f,'drums');f.state['set.drums.tracks']='kick\nleft'
check(not pcall(f.T.set_volume,drums,-3,f.project),'Changing group membership invalidates its pending volume change')
f=fixture();f.left.volume=0;f.T.set_volume(group(f,'drums'),-6,f.project)
check(f.left.volume==0 and near(f.kick.volume,gain),'A silent member stays silent when the rest of its group is adjusted')
f=fixture();f.guitar.volume=0;f.T.set_volume(group(f,'guitar'),-12,f.project)
check(near(f.guitar.volume,10^(-12/20)),'A completely silent single-track instrument can be raised again')
f=fixture();f.fail={track=f.left,key='D_VOL'}
check(not pcall(f.T.set_volume,group(f,'drums'),-9,f.project)and f.kick.volume==1 and f.left.volume==1 and f.right.volume==1,'A failed member-volume write rolls back the entire group')
f=fixture();f.right.mute=1;f.T.toggle_mute(group(f,'drums'),f.project)
check(f.kick.mute==1 and f.left.mute==1 and f.right.mute==1 and f.guitar.mute==0,'Group mute includes all microphones without affecting other instruments')
f.T.toggle_mute(group(f,'drums'),f.project)
check(f.kick.mute==0 and f.left.mute==0 and f.right.mute==1,'Unmuting a group restores microphones that were intentionally muted beforehand')
f.undo();check(f.kick.mute==1 and f.left.mute==1 and f.right.mute==1,'Undo restores the group mute and its saved member states')
f.T.toggle_mute(group(f,'drums'),f.project)
check(f.kick.mute==0 and f.right.mute==1,'Group mute restoration still works after Undo')
f=fixture();f.state.sets=f.state.sets..'\noverlap';f.state['set.overlap.name']='Shared';f.state['set.overlap.tracks']='left\nguitar'
f.T.toggle_mute(group(f,'drums'),f.project);f.T.toggle_mute(group(f,'overlap'),f.project);f.T.toggle_mute(group(f,'drums'),f.project)
check(f.kick.mute==0 and f.left.mute==1 and f.guitar.mute==1,'Unmuting one group does not undo another overlapping group mute')
f.T.toggle_mute(group(f,'overlap'),f.project)
check(f.left.mute==0 and f.guitar.mute==0,'The final overlapping group unmute restores the original track states')
f=fixture();f.fail={track=f.left,key='B_MUTE'}
check(not pcall(f.T.toggle_mute,group(f,'drums'),f.project)and f.kick.mute==0 and f.left.mute==0 and f.kick.props['P_EXT:SoloStudio.group_mutes']=='','A failed group mute restores both audio state and mute metadata')
for _,lock in ipairs({'recording','busy'})do
 f=fixture();drums=group(f,'drums');f[lock]=true;f.draw()
 check(#f.sliders==0 and not f.click('Mute')and not f.click('Rename...')and not f.click('Delete...'),'Group controls are disabled during '..lock)
 check(not pcall(f.T.set_volume,drums,-3,f.project)and not pcall(f.T.toggle_mute,drums,f.project)and not pcall(f.T.rename_group,drums,'New',f.project),'Backend group edits are locked during '..lock)
end
f=fixture();f.left.envelopes={['<VOLENV2']={active=1},['<MUTEENV']={active=1}};f.draw()
check(#f.sliders==3 and group(f,'drums').volume_automated and not pcall(f.T.set_volume,group(f,'drums'),-3,f.project)and not pcall(f.T.toggle_mute,group(f,'drums'),f.project),'Existing member volume and mute automation remain protected')
f.left.envelopes['<VOLENV2'].active=0;f.left.envelopes['<MUTEENV'].active=0;f.revision=f.revision+1;f.draw()
check(#f.sliders==4,'Disabling native automation makes the group controls available again')
f=fixture();f.draw();f.sliders[1].fn(.5)
check(near(f.kick.volume,10^(-18/20))and f.edits==1,'The group volume slider commits the requested linked level')
f=fixture();f.draw();f.click('-1',1)
check(near(f.kick.volume,10^(-1/20))and f.guitar.volume==1,'Fine volume buttons adjust only the chosen group by one dB')
f=fixture();f.kick.volume=10^(18/20);f.draw();f.click('-1',1)
check(near(f.kick.volume,10^(17/20))and near(f.left.volume,10^(-1/20)),'An existing +18 dB fader steps down by one dB without jumping to a lower limit')
f=fixture();f.draw();f.click('+',2);f.draw()
check(labeled(f,'Overheads')and f.click('Rename...',3),'Expanding Other tracks keeps native buses editable')
f=fixture();f.T.set_pan(group(f,'guitar'),-.35,f.project)
check(near(f.guitar.pan,-.35)and f.kick.pan==0 and f.guitar.volume==1 and f.guitar.width==1,'Single-track pan changes only its native pan position')
f.undo();check(f.guitar.pan==0,'Pan is restored by the same native Undo block as other track controls')
f=fixture();f.left.pan=-.5;f.right.pan=.5
local result=f.T.set_pan(group(f,'drums'),.25,f.project)
check(near(result,.25)and near(f.left.pan,-.25)and near(f.right.pan,.75)and near(f.kick.pan,.25),'Linked pan shifts the group while preserving microphone spacing')
result=f.T.set_pan(group(f,'drums'),1,f.project)
check(near(result,.5)and near(f.left.pan,0)and near(f.right.pan,1)and near(f.kick.pan,.5),'Linked pan stops at the first edge without collapsing stereo spacing')
f=fixture();f.left.pan=-1;f.right.pan=1;f.draw();local edits=f.edits
result=f.T.set_pan(group(f,'drums'),.6,f.project)
check(result==0 and f.left.pan==-1 and f.right.pan==1 and f.edits==edits and labeled(f,'Wide'),'A full-width stereo group stays wide and creates no empty Undo entry')
f=fixture();local stale=group(f,'drums');f.left.pan=.2
check(not pcall(f.T.set_pan,stale,.3,f.project)and f.kick.pan==0,'An external pan change cancels a stale linked adjustment')
f=fixture();stale=group(f,'guitar');f.guitar.pan_mode=6
check(not pcall(f.T.set_pan,stale,.3,f.project),'Changing native pan mode cancels a stale adjustment')
f=fixture();stale=group(f,'drums');f.state['set.drums.tracks']='kick\nleft'
check(not pcall(f.T.set_pan,stale,.3,f.project),'Changed group membership invalidates a pending pan edit')
f=fixture();stale=group(f,'drums');f.project='other'
check(not pcall(f.T.set_pan,stale,.3,'song'),'A project switch cancels a pending pan edit')
f=fixture();f.fail={track=f.left,key='D_PAN'}
check(not pcall(f.T.set_pan,group(f,'drums'),.2,f.project)and f.kick.pan==0 and f.left.pan==0,'A failed native pan write restores every member')
for _,lock in ipairs({'recording','busy'})do
 f=fixture();f[lock]=true
 check(not pcall(f.T.set_pan,group(f,'guitar'),.3,f.project),'Pan respects the '..lock..' edit lock')
end
f=fixture();f.guitar.envelopes={['<PANENV2']={active=1}};f.draw()
check(not pcall(f.T.set_pan,group(f,'guitar'),.2,f.project)and labeled(f,'Auto'),'Existing pan automation is protected')
f=fixture();f.guitar.pan_mode=6;f.guitar.pan_left=-.4;f.guitar.pan_right=.4;f.T.set_pan(group(f,'guitar'),.3,f.project)
check(near(f.guitar.pan_left,-.1)and near(f.guitar.pan_right,.7)and f.guitar.pan_mode==6,'Dual-pan tracks move both endpoints without changing their mode or width')
f.guitar.envelopes={['<DUALPANENVR']={active=1}};f.revision=f.revision+1
check(not pcall(f.T.set_pan,group(f,'guitar'),0,f.project),'Dual-pan automation remains protected')
f=fixture();f.draw();f.sliders[2].fn(.75)
check(near(f.kick.pan,.5)and near(f.left.pan,.5)and f.edits==1,'The pan slider commits its position once')
f.draw();f.click('C',1)
check(f.kick.pan==0 and f.left.pan==0,'The C button recenters linked pan')
f=fixture();f.draw();f.answer='-25';f.click('Center',2)
check(near(f.guitar.pan,-.25)and f.kick.pan==0,'Clicking the pan value accepts an exact left/right percentage')
f=fixture()
check(not pcall(f.T.set_pan,group(f,'guitar'),2,f.project)and not pcall(f.T.set_pan,group(f,'guitar'),0/0,f.project),'Invalid pan values are rejected before making changes')
print(total..' track management checks passed.')
