local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(v,label)assert(v,label);total=total+1;print('PASS: '..label)end
local function copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
local function fixture()
 local f={tracks={},undo=0,sets=0,recording=false}
 for n=1,9 do f.tracks[n]={id=tostring(n),lane=0,items={
  {id=n..'a',source='take-a',D_POSITION=8,D_LENGTH=3.01,take={D_STARTOFFS=2,D_PLAYRATE=1,src={len=10}}},
  {id=n..'b',source='take-b',D_POSITION=11,D_LENGTH=3,take={D_STARTOFFS=2,D_PLAYRATE=1,src={len=10}}}}}end
 reaper={
  GetTrackGUID=function(tr)return tr.id end,GetMediaItemInfo_Value=function(it,k)return it[k]or 0 end,
  GetSetMediaItemInfo_String=function(it,k)return true,k=='GUID'and it.id or k=='P_EXT:SoloStudioSource'and it.source or ''end,
  GetActiveTake=function(it)return it.take end,TakeIsMIDI=function(t)return t.midi end,
  GetTakeNumStretchMarkers=function(t)return t.stretch and 1 or 0 end,CountTakeEnvelopes=function(t)return t.envelope and 1 or 0 end,
  GetMediaSourceFileName=function()return 'test.wav'end,
  GetMediaItemTake_Source=function(t)return t.src end,GetMediaSourceLength=function(s)return s.len,s.qn end,
  GetMediaItemTakeInfo_Value=function(t,k)return t[k]or 0 end,
  SetMediaItemTakeInfo_Value=function(t,k,v)t[k]=v;return true end,
  SetMediaItemInfo_Value=function(it,k,v)f.sets=f.sets+1;if f.fail==f.sets then return false end;it[k]=v;return true end,
  GetTrackStateChunk=function(tr)return true,copy(tr)end,
  SetTrackStateChunk=function(tr,saved)for k,v in pairs(saved)do tr[k]=copy(v)end;return true end,
 }
 local M={tracks=function()return f.tracks end,require_tracks=function()return f.tracks end,comp_lane=function(tr)return tr.lane end,
  lane_items=function(tr)return tr.items end,stopped=function()assert(not f.recording)end,
  edit=function(_,fn)f.undo=f.undo+1;fn()end}
 f.B=dofile(root..'/Scripts/solo_comp_edges.lua')(M);return f
end
local f=fixture();local e=f.B.list()[2];local p=f.B.plan(e.key)
check(math.abs(p.low-9.005)<1e-8 and math.abs(p.high-14.004)<1e-8,'Shared boundary range intersects both actual source handles and passage lengths')
f.B.move(e.key,12,p.signature)
local all=true;for _,tr in ipairs(f.tracks)do local a,b=tr.items[1],tr.items[2];all=all and math.abs(a.D_LENGTH-4.005)<1e-8 and math.abs(b.D_POSITION-11.995)<1e-8 and math.abs(b.take.D_STARTOFFS-2.995)<1e-8 end
check(all and f.undo==1,'One edit rolls all nine mics while preserving source timing and crossfade width')
check(not pcall(f.B.move,e.key,10,p.signature)and f.undo==1,'A stale drag cannot overwrite a newer comp edit')
f=fixture();e=f.B.list()[2];f.tracks[9].items[1].take.src.len=5.5
p=f.B.plan(e.key);check(math.abs(p.high-11.495)<1e-8,'The microphone with least available audio limits the whole edit')
check(not pcall(f.B.move,e.key,12)and f.undo==0,'Out-of-media edits are rejected before mutation')
f=fixture();e=f.B.list()[2];f.tracks[5].items[2].D_POSITION=11.5
check(not pcall(f.B.move,e.key,12)and f.undo==0,'Misaligned microphone boundaries are rejected')
f=fixture();e=f.B.list()[2];f.recording=true
check(not pcall(f.B.move,e.key,12)and f.undo==0,'Recording prevents comp-edge edits')
f=fixture();e=f.B.list()[2];f.fail=10
check(not pcall(f.B.move,e.key,12),'Failure on a later microphone is reported')
all=true;for _,tr in ipairs(f.tracks)do all=all and tr.items[1].D_LENGTH==3.01 and tr.items[2].D_POSITION==11 and tr.items[2].take.D_STARTOFFS==2 end
check(all,'A partial failure restores audio bounds and offsets on every microphone')
f=fixture();e=f.B.list()[1];f.B.move(e.key,7)
check(f.tracks[1].items[1].D_POSITION==7 and f.tracks[1].items[1].take.D_STARTOFFS==1,'An outer comp edge can reveal its actual lead-in')
f=fixture();e=f.B.list()[3];f.B.move(e.key,17)
check(f.tracks[1].items[2].D_LENGTH==6,'An outer end can reveal captured tail audio')
f=fixture();e=f.B.list()[2];f.tracks[1].items[2].take.stretch=true
check(not pcall(f.B.move,e.key,12)and f.undo==0,'Stretched takes cannot be trimmed with an invalid linear source mapping')
f=fixture();e=f.B.list()[2];f.tracks[1].items[2].take.envelope=true
check(not pcall(f.B.move,e.key,12)and f.undo==0,'Take automation cannot be shifted accidentally by trimming')
print(total..' comp-edge checks passed.')
