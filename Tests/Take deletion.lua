-- Transaction tests against the real core, without touching REAPER or audio files.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local total=0
local function check(v,label)assert(v,label);total=total+1;print('PASS: '..label)end
local function copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
local function fixture()
 local f={tracks={},state={active='drums',['set.drums.tracks']='kick\nsnare'},undo=0,deletes=0,recording=false}
 for _,name in ipairs({'kick','snare','guitar'})do
  f.tracks[#f.tracks+1]={id=name,count=3,props={P_NAME=name},items={
   {id=name..'a',lane=0,s=0,length=8},{id=name..'b',lane=1,s=8,length=2},
   {id=name..'c',lane=1,s=12,length=3},{id=name..'d',lane=2,s=0,length=16}}}
 end
 reaper={GetProjExtState=function(_,_,k)return 1,f.state[k]or''end,
  GetPlayState=function()return f.recording and 4 or 0 end,
  CountTracks=function()return #f.tracks end,GetTrack=function(_,i)return f.tracks[i+1]end,GetTrackGUID=function(tr)return tr.id end,
  GetMediaTrackInfo_Value=function(tr,k)if k=='I_NUMFIXEDLANES'then return tr.count end;return tr.props[k]or 0 end,
  SetMediaTrackInfo_Value=function(tr,k,v)if not(f.switch_fail and tr.id=='snare')then tr.props[k]=v end end,
  GetSetMediaTrackInfo_String=function(tr,k,v,set)if set then tr.props[k]=v end;return true,tr.props[k]or''end,
  GetSetMediaItemInfo_String=function(it,k)return true,k=='GUID'and it.id or ''end,
  GetMediaItemInfo_Value=function(it,k)return k=='I_FIXEDLANE'and it.lane or k=='D_POSITION'and it.s or it.length end,
  CountTrackMediaItems=function(tr)return #tr.items end,GetTrackMediaItem=function(tr,i)return tr.items[i+1]end,
  GetTrackStateChunk=function(tr)return not f.snapshot_fail,copy(tr)end,
  SetTrackStateChunk=function(tr,saved)for k,v in pairs(saved)do tr[k]=copy(v)end;return true end,
  DeleteTrackMediaItem=function(tr,it)
   f.deletes=f.deletes+1;if f.fail_at==f.deletes then return false end
   for i,v in ipairs(tr.items)do if v==it then table.remove(tr.items,i);return true end end;return false
  end,
  Undo_BeginBlock2=function()f.undo=f.undo+1;f.before=copy(f.tracks)end,
  Undo_EndBlock2=function()end,PreventUIRefresh=function()end,UpdateTimeline=function()end,TrackList_AdjustWindows=function()end}
 f.M=dofile(root..'/Scripts/solo_core.lua');return f
end
local f=fixture();f.M.delete_take(1,'kickb')
check(#f.tracks[1].items==2 and #f.tracks[2].items==2,'Entire split pass removed across both microphones')
check(#f.tracks[3].items==4,'Other instrument recordings untouched')
check(f.tracks[1].items[1].id=='kicka'and f.tracks[1].items[2].id=='kickd','Adjacent takes preserved')
check(f.tracks[1].count==3 and f.tracks[2].count==3,'Empty native lanes retained to preserve comp and microphone indices')
check(f.undo==1,'One undo block contains the whole deletion')
f=fixture();f.fail_at=3
check(not pcall(f.M.delete_take,1,'kickb'),'Failure on a later microphone is reported')
check(#f.tracks[1].items==4 and #f.tracks[2].items==4 and f.tracks[1].items[2].id=='kickb','Partial failure restores all original track contents')
f=fixture();f.tracks[2].count=4
check(not pcall(f.M.delete_take,1,'kickb')and f.deletes==0 and f.undo==0,'Mismatched microphone lane counts rejected before mutation')
f=fixture()
check(not pcall(f.M.delete_take,1,'old-key')and f.deletes==0,'Stale take identity cannot delete a different pass')
f=fixture();f.recording=true
check(not pcall(f.M.delete_take,1,'kickb')and f.deletes==0,'Deletion rejected while recording')
f=fixture();f.snapshot_fail=true
check(not pcall(f.M.delete_take,1,'kickb')and f.deletes==0,'Snapshot failure leaves all recordings untouched')
f=fixture();f.tracks[1].props['P_EXT:SoloStudioComp']='kickb\nkickc';f.tracks[2].props['P_EXT:SoloStudioComp']='snareb\nsnarec'
f.M.delete_take(1,'kickb')
check(f.tracks[1].props['P_EXT:SoloStudioComp']==''and f.tracks[2].props['P_EXT:SoloStudioComp']=='','Deleting a comp clears only its deleted item references')
f=fixture();f.tracks[1].props['P_EXT:SoloStudioComp']='kickd';f.M.delete_take(1,'kickb')
check(f.tracks[1].props['P_EXT:SoloStudioComp']=='kickd','Deleting a source leaves the separate comp intact')
f=fixture();table.remove(f.tracks[2].items,3);table.remove(f.tracks[2].items,2);f.M.delete_take(1,'kickb')
check(#f.tracks[1].items==2 and #f.tracks[2].items==2,'Incomplete multitrack pass can be removed without deleting other lanes')
f=fixture();f.M.delete_takes({{lane=0,key='kicka'},{lane=2,key='kickd'}})
check(#f.tracks[1].items==2 and #f.tracks[2].items==2 and f.tracks[1].items[1].id=='kickb','Disjoint batch deletes only selected takes across microphones')
check(f.undo==1 and #f.tracks[3].items==4,'Batch deletion uses one undo step and preserves other instruments')
f=fixture();f.M.delete_takes(f.M.lanes())
check(#f.tracks[1].items==0 and #f.tracks[2].items==0 and f.undo==1,'All takes can be removed together')
f=fixture();f.fail_at=4
check(not pcall(f.M.delete_takes,{{lane=0,key='kicka'},{lane=2,key='kickd'}}),'Failure halfway through batch deletion is reported')
check(#f.tracks[1].items==4 and #f.tracks[2].items==4,'Batch failure restores every selected take on every microphone')
f=fixture()
check(not pcall(f.M.delete_takes,{{lane=0,key='kicka'},{lane=2,key='stale'}})and f.deletes==0,'Every selected identity is checked before deleting any take')
f=fixture();f.M.delete_takes({{lane=1,key='kickb'},{lane=1,key='kickb'}})
check(f.deletes==4 and f.undo==1,'Duplicate batch entries do not delete twice')
f=fixture();check(not pcall(f.M.delete_takes,{})and f.undo==0,'Empty batches cannot create edits')
f=fixture();f.M.delete_takes({{lane=1,key='kickb'}},'kickd')
check(f.undo==1 and #f.tracks[1].items==2 and f.tracks[1].props['C_LANEPLAYS:2']==1 and f.tracks[2].props['C_LANEPLAYS:2']==1,'Deletion and follow-selection playback share one undo block across microphones')
f=fixture();f.switch_fail=true
check(not pcall(f.M.delete_takes,{{lane=1,key='kickb'}},'kickd')and #f.tracks[1].items==4 and #f.tracks[2].items==4 and not f.tracks[1].props['C_LANEPLAYS:2'],'A failed neighbor switch rolls back both deletion and playback on all microphones')
f=fixture()
check(not pcall(f.M.delete_takes,{{lane=1,key='kickb'}},'stale')and f.undo==0 and f.deletes==0,'A stale neighbor cannot cause deletion')
check(not pcall(f.M.delete_takes,{{lane=1,key='kickb'}},'kickb')and f.undo==0,'A deleted lane cannot be its own playback successor')
print(total..' take deletion checks passed.')
