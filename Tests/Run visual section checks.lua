-- Native region checks and a disposable visual fixture. Close the panel to restore the user's song.
local R=reaper
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local M=dofile(root..'/Scripts/solo_core.lua');local S=M.sections()
assert(R.GetPlayState()==0,'Stop transport before checking the visual editor.')
local original=R.EnumProjects(-1,'')
local snapshot={items=R.CountMediaItems(0),tracks=R.CountTracks(0),markers=R.CountProjectMarkers(0),tempo=R.Master_GetTempo()}
local filename=root..'/Tests/Visual timeline checks.RPP'
local f=assert(io.open(filename,'w'));f:write('<REAPER_PROJECT 0.1 7.55 1\n TEMPO 120 4 4\n>\n');f:close()
R.Main_OnCommand(41929,0);R.Main_openProject(filename)
local project=R.EnumProjects(-1,'')
local log=assert(io.open(root..'/Tests/visual-section-checks.txt','w'));local count=0
local function check(value,label)assert(value,label);count=count+1;log:write('PASS: '..label..'\n');log:flush()end
local function cleanup()
 if R.ValidatePtr(project,'ReaProject*')then
  R.SelectProjectInstance(project);R.OnStopButton();R.Main_SaveProjectEx(project,filename,8);R.Main_OnCommand(40860,0)
 end
 R.SelectProjectInstance(original)
 check(R.CountMediaItems(0)==snapshot.items and R.CountTracks(0)==snapshot.tracks and R.CountProjectMarkers(0)==snapshot.markers and R.Master_GetTempo()==snapshot.tempo,'User song media, tracks, regions, and tempo preserved')
 log:write(count..' native visual-section checks passed.\n');log:close()
end
local ok,err=xpcall(function()
 M.add_instrument('Scratch guitar + vocal',{'Test guitar','Test vocal'})
 local intro=S.create(0,8,'Intro');local verse=S.create(8,24,'Verse');local chorus=S.create(24,40,'Chorus')
 S.select(verse.key);S.edge(verse.key,'e',26)
 check(S.find(verse.key).e==26 and S.find(chorus.key).s==26,'Shared boundary updates both native regions')
 local a,b=R.GetSet_LoopTimeRange2(0,false,false,0,0,false)
 check(a==8 and b==26,'Selected recording range follows edited boundary')
 check(not pcall(S.edge,verse.key,'e',42),'Boundary cannot cross the next section')
 check(S.find(verse.key).e==26 and S.find(chorus.key).s==26,'Rejected boundary leaves regions unchanged')
 R.Undo_DoUndo2(0)
 check(S.find(verse.key).e==24 and S.find(chorus.key).s==24,'Single undo restores both region edges')
 check(S.parse_position('9')==16 and S.parse_position('9.1.00')==16,'Whole bar and bar.beat inputs agree')
 check(math.abs(S.parse_position('9.2.00')-16.5)<0.00001,'Beat positions use the native musical time map')
 check(not pcall(S.parse_position,'garbage') and not pcall(S.parse_position,'0'),'Invalid positions are rejected')
 local ending=S.end_after_bars(16,8);log:write('Eight-bar endpoint: '..string.format('%.17g',ending)..'\n')
 check(math.abs(ending-32)<0.00001,'Eight bars starting at bar 9 ends at bar 17')
 check(not pcall(S.end_after_bars,0,0),'Zero-length numeric sections are rejected')
 S.select(verse.key);S.edge(verse.key,'s',10)
 check(S.find(intro.key).e==10 and S.find(verse.key).s==10,'Start-edge editing updates the preceding region')
 S.edge(verse.key,'s',8)
 check(R.CountMediaItems(0)==0,'Section editing never creates or alters audio')
 R.SetExtState(M.ns,'panel_view','timeline',false)
 R.Main_SaveProjectEx(project,filename,8)
end,debug.traceback)
if not ok then log:write('FAIL: '..err..'\n');cleanup();R.ShowMessageBox(err,'Visual section checks failed',0);return end
dofile(root..'/Scripts/Solo Studio - Open recording panel.lua')
R.atexit(cleanup)
