local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(ok,label)assert(ok,label);total=total+1;print('PASS: '..label)end
local function fixture()
 local f={project={},state={},recording=false,master={{D_VOL=0.8,I_SRCCHAN=0.0,I_DSTCHAN=0.0}},track={{D_VOL=0.4,I_SRCCHAN=0.0,I_DSTCHAN=2.0}}}
 reaper={
  ValidatePtr=function()return true end,
  GetMasterTrack=function()return f.master end,CountTracks=function()return 1 end,GetTrack=function()return f.track end,
  GetTrackGUID=function()return 'guide-guid'end,GetTrackNumSends=function(tr)return #tr end,
  GetTrackSendInfo_Value=function(tr,_,i,key)return tr[i+1][key]end,
  SetTrackSendInfo_Value=function(tr,_,i,key,value)tr[i+1][key]=value end,
  GetProjExtState=function(_,_,key)return 1,f.state[key]or''end,
  SetProjExtState=function(_,_,key,value)f.state[key]=value end,
  GetPlayStateEx=function()return f.recording and 5 or 0 end,
 }
 f.D=dofile(root..'/Scripts/solo_leadin.lua');return f
end
local f=fixture();f.D.begin(f.project,'a',8)
check(math.abs(f.master[1].D_VOL-0.8*f.D.gain)<1e-9 and math.abs(f.track[1].D_VOL-0.4*f.D.gain)<1e-9,'Master and direct track hardware playback are dimmed once')
f.D.restore(f.project,'a');check(f.master[1].D_VOL==0.8 and f.track[1].D_VOL==0.4,'Original output gains restored with native floating-point channel values')
f=fixture();f.D.begin(f.project,'a',8);f.D.restore(f.project,'other');check(f.master[1].D_VOL<0.8,'A stale helper cannot restore a different pass')
f.D.begin(f.project,'b',8);check(math.abs(f.master[1].D_VOL-0.8*f.D.gain)<1e-9,'Repeated takes do not accumulate attenuation')
f.D.restore(f.project,'b');check(f.master[1].D_VOL==0.8,'Replacement take retains the original level')
f=fixture();f.D.begin(f.project,'a',8);f.master[1].D_VOL=0.25;f.D.restore(f.project,'a')
check(f.master[1].D_VOL==0.25 and f.track[1].D_VOL==0.4,'Intentional manual output changes are preserved')
f=fixture();f.D.begin(f.project,'a',8);f.track[1].I_DSTCHAN=4;f.D.restore(f.project,'a')
check(f.track[1].D_VOL~=0.4 and f.master[1].D_VOL==0.8,'Routing changes are not overwritten by stale restoration')
f=fixture();f.D.begin(f.project,'a',0);check(f.master[1].D_VOL==0.8 and not next(f.state),'Song-start count-in does not dim music unnecessarily')
f=fixture();f.D.begin(f.project,'a',8);f.recording=true;f.D.recover(f.project)
check(f.master[1].D_VOL<0.8,'Opening the panel during recording does not undo its lead-in')
f.recording=false;f.D.recover(f.project);check(f.master[1].D_VOL==0.8 and f.state[f.D.key]=='','Interrupted lead-in can recover from saved project state')
print(total..' lead-in restoration checks passed.')
