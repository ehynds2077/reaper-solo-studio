-- Real rendering, archive recovery, and failure cleanup in disposable projects.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local B=dofile(root..'/Scripts/solo_bounces.lua');local J=B.json
assert(R.GetPlayState()==0,'Stop transport before running bounce checks.')
local original=R.EnumProjects(-1,'');local original_revision=R.GetProjectStateChangeCount(original)
local log=assert(io.open(root..'/Tests/bounce-checks.txt','w'));local passed=0
local function check(value,label)assert(value,label);passed=passed+1;log:write('PASS '..label..'\n');log:flush()end
local function chunks(project)
 local data={}
 for i=-1,R.CountTracks(project)-1 do local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i);local ok,c=R.GetTrackStateChunk(tr,'',false);assert(ok);data[#data+1]=c end
 return table.concat(data,'\n')
end
local original_chunks=chunks(original);local project;local finished=false
local filename=root..'/Tests/Bounce checks.RPP'
local function cleanup(error)
 if finished then return end;finished=true
 if project and R.ValidatePtr(project,'ReaProject*')then R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)end
 R.SelectProjectInstance(original)
 check(chunks(original)==original_chunks and R.GetProjectStateChangeCount(original)==original_revision,'User song remains exactly unchanged')
 if error then log:write('FAIL '..error..'\n')end
 log:write(passed..' native bounce checks passed\n');log:close()
end
local row,started
local ok,error=xpcall(function()
 R.Main_OnCommand(41929,0);project=R.EnumProjects(-1,'')
 local master=R.GetMasterTrack(project);for i=R.GetTrackNumSends(master,1)-1,0,-1 do R.RemoveTrackSend(master,1,i)end
 for i,name in ipairs({'Guitar','Lead vocals'})do
  R.InsertTrackAtIndex(i-1,false);local tr=R.GetTrack(project,i-1);R.GetSetMediaTrackInfo_String(tr,'P_NAME',name,true)
  local item=R.AddMediaItemToTrack(tr);local take=R.AddTakeToMediaItem(item)
  R.SetMediaItemTake_Source(take,assert(R.PCM_Source_CreateFromFile(root..'/Tests/bounce-'..i..'.wav')))
  R.SetMediaItemInfo_Value(item,'D_LENGTH',2);R.SetMediaTrackInfo_Value(tr,'I_RECARM',1)
  if i==2 then
   local _,chunk=R.GetTrackStateChunk(tr,'',false)
   chunk=chunk:gsub('>%s*$', '<MUTEENV\nACT 1 -1\nVIS 1 1 1\nARM 1\nDEFSHAPE 0 -1 -1\nPT 0 1 0\n>\n>\n')
   assert(R.SetTrackStateChunk(tr,chunk,false))
  end
 end
 R.Main_SaveProjectEx(project,filename,8)
 R.SetMediaTrackInfo_Value(R.GetTrack(project,0),'D_PAN',-.2);R.MarkProjectDirty(project)
 local before=chunks(project);local dirty=R.IsProjectDirty(project);local revision=R.GetProjectStateChangeCount(project)
 local cursor=R.GetCursorPosition();local settings=R.GetSetProjectInfo(project,'RENDER_SRATE',0,false)
 B.root=root..'/Tests/Bounce test data'
 row=B.export({title='Archive regression',notes='Synthetic guitar at 220 Hz and vocal at 880 Hz.',bounds={0,2}})
 J.write(root..'/Tests/bounce-test-result.json',{folder=row.folder})
 check(R.EnumProjects(-1,'')==project and select(2,R.EnumProjects(-1,''))==filename,'Export returns to the original working project filename')
 check(chunks(project)==before,'Rendering instrumental leaves all working tracks and input arming intact')
 check(R.IsProjectDirty(project)==dirty,'Unsaved working edits remain marked unsaved')
 check(R.GetProjectStateChangeCount(project)==revision,'Snapshot/render does not invalidate current AI mix review')
 check(R.GetCursorPosition()==cursor and R.GetSetProjectInfo(project,'RENDER_SRATE',0,false)==settings,'Cursor and render settings preserved')
 check(#row.vocals==1 and row.vocals[1].name=='Lead vocals','Vocal detection selects the vocal source')
 started=R.time_precise()
end,debug.traceback)
if not ok then cleanup(error);return end
local function tick()
 local ok,error=xpcall(function()
  local status=B.read_status(row)
  assert(not status or status.state~='failed',status and status.message)
  assert(R.time_precise()-started<60,'Archive worker did not finish')
  if not status or status.state~='ready'then R.defer(tick);return end
  check(true,'Worker completes both M4A copies and source archive')
  local snapshot=assert(io.open(row.folder..'/Session.RPP'));local text=snapshot:read('*a');snapshot:close()
  check(text:find('../_Media/',1,true)~=nil,'Archived session points to preserved media')
  local old=R.PCM_Source_CreateFromFile
  R.PCM_Source_CreateFromFile=function()return nil end -- Simulate cancelled render detection.
  local before=chunks(project);local success=pcall(B.export,{title='Cancelled render',bounds={0,2}})
  R.PCM_Source_CreateFromFile=old
  check(not success and R.EnumProjects(-1,'')==project and chunks(project)==before,'Cancelled render restores the working project without changing tracks')
  row.status='ready';B.open_session(row)
  local reopened=R.EnumProjects(-1,'')
  check(reopened~=project and R.CountTracks(reopened)==2 and select(2,R.EnumProjects(-1,''))=='','Saved full mix opens as a new unsaved copy, protecting the archive')
  check(B.identity().id==row.project_id and #B.list()>0,'Reopened session retains its original song bounce history')
  local source=R.GetMediaItemTake_Source(R.GetActiveTake(R.GetMediaItem(reopened,0)))
  check(R.GetMediaSourceLength(source)>=2,'Reopened snapshot resolves archived source recording')
  R.Main_SaveProjectEx(reopened,root..'/Tests/Restored bounce.RPP',8);R.Main_OnCommand(40860,0);R.SelectProjectInstance(project)
  cleanup()
 end,debug.traceback)
 if not ok then cleanup(error)end
end
R.defer(tick)
