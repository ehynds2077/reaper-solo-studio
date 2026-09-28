-- Real core, track manager, and Tracks view against a small project fixture.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={tracks={},state={},revision=0,project='song',recording=false,edits=0,buttons={},labels={},confirm=7}
 local function add(key,name,depth,items)
  local tr={key=key,name=name,delta=depth,items=items or 0,fx=2,input=0};f.tracks[#f.tracks+1]=tr;return tr
 end
 f.folder=add('folder','Drums',1);f.kick=add('kick','Kick',0,6);f.inner=add('oh','Overheads',1)
 f.left=add('left','OH L',0,6);f.right=add('right','OH R',-2,6);f.guitar=add('guitar','Guitar',0,2)
 f.state={sets='drums\nguitar',active='drums',['set.drums.tracks']='kick\nleft\nright',['set.drums.name']='Drums',
  ['set.guitar.tracks']='guitar',['set.guitar.name']='Guitar'}
 reaper={
  CountTracks=function()return #f.tracks end,GetTrack=function(_,i)return f.tracks[i+1]end,
  GetTrackGUID=function(tr)return tr.key end,CountTrackMediaItems=function(tr)return tr.items end,
  TrackFX_GetCount=function(tr)return tr.fx end,IsTrackSelected=function(tr)return tr.selected or false end,
  GetMediaTrackInfo_Value=function(tr,key)return key=='I_FOLDERDEPTH'and tr.delta or key=='I_RECINPUT'and tr.input or 0 end,
  SetMediaTrackInfo_Value=function(tr,key,value)assert(key=='I_FOLDERDEPTH');tr.delta=value;f.revision=f.revision+1;return true end,
  GetSetMediaTrackInfo_String=function(tr,key,value,set)assert(key=='P_NAME');if set then tr.name=value;f.revision=f.revision+1 end;return true,tr.name end,
  GetProjExtState=function(_,_,key)return 1,f.state[key]or ''end,SetProjExtState=function(_,_,key,value)f.state[key]=value end,
  EnumProjects=function()return f.project end,GetPlayState=function()return f.recording and 4 or 0 end,
  GetProjectStateChangeCount=function()return f.revision end,
  ValidatePtr2=function(_,tr)for _,candidate in ipairs(f.tracks)do if tr==candidate then return true end end;return false end,
  DeleteTrack=function(tr)for i,candidate in ipairs(f.tracks)do if candidate==tr then table.remove(f.tracks,i);f.revision=f.revision+1;return end end;error('Missing track')end,
  Undo_BeginBlock2=function()f.edits=f.edits+1 end,Undo_EndBlock2=function()end,PreventUIRefresh=function()end,
  UpdateTimeline=function()end,TrackList_AdjustWindows=function()end,MarkProjectDirty=function()end,
  SetTrackSelected=function(tr,value)tr.selected=value end,
  GetUserInputs=function()return f.answer~=nil,f.answer end,
  ShowMessageBox=function(message)f.dialog=message;return f.confirm end,
 }
 local M=dofile(root..'/Scripts/solo_core.lua');local T=dofile(root..'/Scripts/solo_tracks.lua')(M)
 f.M,f.T=M,T
 gfx={mouse_x=0,mouse_y=0,rect=function()end}
 local V=dofile(root..'/Scripts/solo_tracks_view.lua')(M,{colors={muted={},text={},surface={},record={}},
  text=function(label)f.labels[#f.labels+1]=label end,color=function()end,
  button=function(label,x,y,w,h,fn,_,enabled)if enabled~=false then f.buttons[#f.buttons+1]={label=label,y=y,fn=fn}end end,
  hit=function(_,_,_,_,fn,enabled)if enabled then f.select=fn end end,
  changed=function(message)f.message=message end})
 function f.draw()f.buttons={};f.labels={};V.draw(24,215,1152,476,f.recording)end
 function f.click(label,index)local n=0;for _,b in ipairs(f.buttons)do if b.label==label then n=n+1;if n==(index or 1)then b.fn();return true end end end;return false end
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
check(f.dialog:find('4 child tracks',1,true)and f.dialog:find('18 audio/MIDI items',1,true),'Delete confirmation states exactly how much of the folder will be removed')
check(#f.tracks==6 and f.edits==0,'Cancelling the confirmation leaves every track intact')
f.confirm=6;f.click('Delete...',1)
check(#f.tracks==1 and f.message:find('Deleted 5 tracks',1,true),'Confirming deletes only the reviewed folder in one operation')
f=fixture();f.draw();f.answer='Kick close';f.click('Rename...',2)
check(f.kick.name=='Kick close'and f.message:find('Track renamed',1,true),'The row Rename button changes the selected native track')
f=fixture();f.recording=true;f.draw()
check(not f.click('Rename...')and not f.click('Delete...'),'Tracks view disables destructive row actions during recording')
print(total..' track management checks passed.')
