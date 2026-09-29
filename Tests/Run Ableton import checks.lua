-- Run after Tests/make_ableton_fixture.py. Isolated project, no hardware outputs.
local R=reaper;R.defer(function()end)
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local J=dofile(root..'/Scripts/solo_json.lua');local A=dofile(root..'/Scripts/solo_ableton.lua')
local folder='/private/tmp/Tests/solo-ableton-native-plan'
local original=R.EnumProjects(-1,'');local revision=R.GetProjectStateChangeCount(original)
local project;local checks=0
local function check(ok,message)assert(ok,message);checks=checks+1 end
local ok,err=xpcall(function()
 local plan=assert(J.read(folder..'/import-plan.json'));local report
 project,report=A.apply(plan,{silent=true})
 check(report.ok,'Import failed');check(report.original_unchanged,'Original modified')
 check(R.CountTracks(project)==4,'Track count');check(report.clips==5,'Clip count')
 check(report.automation==5,'Automation count')
 local group=R.GetTrack(project,0);local audio=R.GetTrack(project,1);local midi=R.GetTrack(project,2)
 check(R.GetMediaTrackInfo_Value(group,'I_FOLDERDEPTH')==1,'Group nesting')
 check(R.GetMediaTrackInfo_Value(midi,'I_FOLDERDEPTH')==-1,'Folder close')
 check(R.GetMediaTrackInfo_Value(audio,'B_MAINSEND')==0,'No duplicate routing')
 check(R.GetTrackNumSends(audio,0)==2,'Group output plus return send')
 check(R.GetMediaTrackInfo_Value(audio,'I_NUMFIXEDLANES')==2,'Take lanes')
 check(R.GetMediaTrackInfo_Value(audio,'C_LANEPLAYS:0')==1,'Comp plays')
 check(R.GetMediaTrackInfo_Value(audio,'C_LANEPLAYS:1')==0,'Inactive take is silent')
 local item=R.GetTrackMediaItem(audio,0);local take=R.GetActiveTake(item)
 check(math.abs(R.GetMediaItemInfo_Value(item,'D_POSITION')-4)<1e-8,'Trim position')
 check(math.abs(R.GetMediaItemTakeInfo_Value(take,'D_STARTOFFS')-2)<1e-8,'Source trim')
 local _,pos,src=R.GetTakeStretchMarker(take,0)
 check(pos==0 and src==2,'Warp source position')
 local _,notes,cc=R.MIDI_CountEvts(R.GetActiveTake(R.GetTrackMediaItem(midi,0)))
 check(notes==2 and cc==1,'MIDI notes and sustain')
 local pan=R.GetTrackEnvelopeByChunkName(audio,'<PANENV2');check(pan and R.CountEnvelopePoints(pan)==2,'Pan envelope')
 local volume=R.GetTrackEnvelopeByChunkName(audio,'<VOLENV2');check(volume and R.CountEnvelopePoints(volume)==2,'Volume envelope')
 local ret=R.GetTrack(project,3);local _,chunk=R.GetTrackStateChunk(ret,'',false)
 local found=chunk:find('<AUXVOLENV')and chunk:find('PT 4 0.7',1,true)
 check(found,'Send envelope persisted')
 for _,p in ipairs(report.plugins)do
  check(p.status=='state restored',p.name..' state not restored')
  check(#p.parameter_differences==0,p.name..' exposed parameters differ from Live')
 end
 check(R.GetTrackNumSends(R.GetMasterTrack(project),1)==0,'Test hardware outputs disabled')
 local _,path=R.EnumProjects(-1,'');check(path==report.project,'Project saved')
end,debug.traceback)
if project and R.ValidatePtr(project,'ReaProject*')then R.SelectProjectInstance(project);R.Main_SaveProjectEx(project,folder..'/Fixture.RPP',8);R.Main_OnCommand(40860,0)end
R.SelectProjectInstance(original)
J.write(folder..'/checks.json',{ok=ok,error=err,checks=checks,unchanged=R.GetProjectStateChangeCount(original)==revision})
