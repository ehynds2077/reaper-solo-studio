-- Native project/template verification; never records or edits the user's song.
local R=reaper;local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
R.defer(function()end)
assert(R.GetAllProjectPlayStates()&4==0 and R.GetPlayState()==0,'Stop transport before these checks.')
local original,original_path=R.EnumProjects(-1,'');local revision=R.GetProjectStateChangeCount(original);local dirty=R.IsProjectDirty(original)
local function chunks(project)
 local out={};for i=-1,R.CountTracks(project)-1 do local tr=i==-1 and R.GetMasterTrack(project)or R.GetTrack(project,i);local ok,text=R.GetTrackStateChunk(tr,'',false);assert(ok);out[#out+1]=text end
 return table.concat(out,'\n')
end
local before=chunks(original);local log=assert(io.open(root..'/Tests/project-library-checks.txt','w'));local passed=0
local function check(value,label)assert(value,label);passed=passed+1;log:write('PASS '..label..'\n');log:flush()end
local M=dofile(root..'/Scripts/solo_core.lua')
local factory=dofile(root..'/Scripts/solo_projects.lua')
local base=root..'/Tests/Project library data';local serial=R.genGuid():gsub('[^%w]',''):sub(1,10)
local P=factory(M,{root=base,catalog=base..'/catalog.json',template=root..'/Templates/Solo Studio - Ethan X32.RPP',ini=base..'/absent.ini'})
local work,path,unsaved,copy
local ok,err=xpcall(function()
 work,path=P.create('New song '..serial,137,original)
 check(R.EnumProjects(-1,'')==work and select(2,R.EnumProjects(-1,''))==path,'New song is named and saved in its own folder')
 check(R.CountTracks(work)==15 and R.CountMediaItems(work)==0,'Full-band template contains 15 tracks and no recorded audio')
 local sets=M.sets();local names={};for _,set in ipairs(sets)do names[set.name]=set end
 check(#sets==6 and names.Drums and names.Bass and names.Vocals and names['Electric guitar']and names['Acoustic guitar']and names['Scratch guitar + vocal'],'All six recording sets resolve after loading as a native template')
 check(M.get('active')==names['Scratch guitar + vocal'].id and #M.tracks()==2,'Scratch guitar and vocal are selected')
 local expected={['Scratch vocal']=8,['Scratch guitar']=14,Vocals=8,['Electric guitar']=14,['Acoustic guitar']=-1,Bass=-1,Kick=0,['Snare top']=1,['Snare bottom']=2,['Tom 1']=3,['Tom 2']=4,['Hi-hat']=5,['Overhead L']=6,['Overhead R']=7,Ride=10}
 local armed=0
 for i=0,R.CountTracks(work)-1 do
  local tr=R.GetTrack(work,i);local _,name=R.GetTrackName(tr)
  check(expected[name]~=nil and R.GetMediaTrackInfo_Value(tr,'I_RECINPUT')==expected[name] and R.GetMediaTrackInfo_Value(tr,'I_RECMON')==0,name..' keeps its X32 input and hardware monitoring')
  armed=armed+R.GetMediaTrackInfo_Value(tr,'I_RECARM')
 end
 check(armed==2,'Only the two scratch tracks are armed')
 local _,recordpath=R.GetSetProjectInfo_String(work,'RECORD_PATH','',false)
 check(recordpath=='Media'and math.abs(R.GetProjectTimeSignature2(work)-137)<.01,'Relative Media folder and requested tempo are saved')
 M.choose_set(names.Drums.id);check(#M.tracks()==9,'Nine drum microphones remain linked to the Drums recording set')
 R.SetMediaTrackInfo_Value(R.GetTrack(work,0),'D_PAN',-.27);R.MarkProjectDirty(work)
 local snapshot=chunks(work);local changes=R.GetProjectStateChangeCount(work)
 if original_path~=''then P.add(original_path)end -- Existing open user song only enters the test catalog.
 P.open({project=original,path=original_path})
 check(R.EnumProjects(-1,'')==original and chunks(work)==snapshot and R.IsProjectDirty(work)~=0,'Switching away preserves unsaved tracks in the previous tab')
 P.open({path=path})
 check(R.EnumProjects(-1,'')==work and chunks(work)==snapshot and R.GetProjectStateChangeCount(work)==changes,'Returning to an open song reuses its exact in-memory state')
 check(not pcall(P.create,'New song '..serial,120),'Duplicate song name cannot overwrite an existing project')
 R.Main_SaveProjectEx(work,path,8);R.Main_OnCommand(40860,0);work=nil
 P.open({path=path});work=R.EnumProjects(-1,'')
 check(R.CountTracks(work)==15 and #M.sets()==6 and #M.tracks()==9,'Closed song reopens from its saved .RPP with recording sets intact')
 R.Main_OnCommand(41929,0);unsaved=R.EnumProjects(-1,'');R.InsertTrackAtIndex(0,false);R.MarkProjectDirty(unsaved)
 P.open({path=path});P.open({project=unsaved,path=''})
 check(R.EnumProjects(-1,'')==unsaved and select(2,R.EnumProjects(-1,''))==''and R.CountTracks(unsaved)==1,'Unsaved unnamed project survives a round trip')
 R.Main_SaveProjectEx(unsaved,base..'/Unsaved '..serial..'.RPP',8);R.Main_OnCommand(40860,0);unsaved=nil
 local real=factory(M,{catalog=base..'/discovery.json',root=(os.getenv('HOME')or '')..'/Desktop/Solo Studio Songs'})
 R.SelectProjectInstance(original);real.refresh()
 local found=false;for _,row in ipairs(real.list())do
  if row.project==original then found=true end
  check(not row.path:find('/Templates/',1,true)and not row.path:find('/Tests/',1,true),'Automatic discovery excludes templates and development fixtures')
 end
 check(found,'Existing user song is discovered from open projects and recent files')
end,debug.traceback)
for _,proj in ipairs({unsaved or false,work or false})do if proj and R.ValidatePtr(proj,'ReaProject*')then R.SelectProjectInstance(proj);R.Main_SaveProjectEx(proj,base..'/Cleanup '..serial..'.RPP',8);R.Main_OnCommand(40860,0)end end
R.SelectProjectInstance(original)
check(chunks(original)==before and R.IsProjectDirty(original)==dirty and R.GetProjectStateChangeCount(original)==revision,'User song track chunks, dirty state and revision remain exactly unchanged')
if not ok then log:write('FAIL '..tostring(err)..'\n')end
log:write(passed..' native project checks passed\n');log:close()
