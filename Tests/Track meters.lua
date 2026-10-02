-- Native meter aggregation and ballistics with no audio engine or project edits.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local calls=0
reaper={Track_GetPeakInfo=function(track,ch)calls=calls+1;return track[ch+1]end}
local M=dofile(root..'/Scripts/solo_track_meters.lua')()
local left={.5,.1};local right={.2,.8}
local a={key='left',track=left};local b={key='right',track=right}
local row={key='drums',members={a,b}}
local n=0;local function check(ok,label)assert(ok,label);n=n+1;print('PASS '..label)end
local function near(a,b)return math.abs(a-b)<1e-8 end
M.begin_frame('song',0);local state=M.read(row)
check(near(state.level[1],20*math.log(.5,10))and near(state.level[2],20*math.log(.8,10)),'Group uses channel maxima, not a misleading sum of member peaks')
M.read({key='left',members={a}})
check(calls==4,'Expanded tracks reuse the same frame sample instead of polling twice')
left[1]=1.1;M.begin_frame('song',.1);state=M.read(row)
check(state.level[1]>0 and state.clipped,'Overload is detected immediately and latched')
left[1]=0;right[1]=0;M.begin_frame('song',.2);state=M.read(row)
check(near(state.level[1],20*math.log(1.1,10)-2.4)and state.peak[1]>0,'Meter decays in dB while transient peak stays held')
M.begin_frame('song',1.4);state=M.read(row)
check(near(state.peak[1],20*math.log(1.1,10)-2.4)and state.clipped,'Peak releases only after its hold expires; overload remains visible')
M.clear(row.key);M.begin_frame('song',1.5);state=M.read(row)
check(not state.clipped and state.level[1]==-60,'Clearing resets the local overload and held peak')
left[1]=2;M.begin_frame('song',2);M.read(row);left[1]=0
M.begin_frame('another song',2.1);state=M.read(row)
check(not state.clipped and state.level[1]==-60,'Switching project clears meter history even with identical row names')
left[1]=2;M.begin_frame('another song',2.2);M.read(row)
row.members={b};M.begin_frame('another song',2.3);state=M.read(row)
check(not state.clipped and state.level[1]==-60,'Removing a hot member clears obsolete group peaks')
right[1]=0/0;right[2]=math.huge;M.begin_frame('another song',20);state=M.read(row)
check(state.level[1]==-60 and state.level[2]==-60 and not state.clipped,'Invalid native values cannot create a false overload or invalid geometry')
check(M.position(-90)==0 and M.position(6)==1 and M.position(-30)==.5,'dB scale clamps drawing to meter bounds')
print(n..' track meter checks passed')
