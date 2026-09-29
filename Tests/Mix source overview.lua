-- Source overview scope: active lanes, MIDI, missing peaks, offsets and pagination.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local items={
 {D_POSITION=105,D_LENGTH=5,C_LANEPLAYS=1,take={}},
 {D_POSITION=100,D_LENGTH=20,C_LANEPLAYS=0,take={}},
 {D_POSITION=100,D_LENGTH=20,C_LANEPLAYS=1,B_MUTE=1,take={}},
 {D_POSITION=112,D_LENGTH=3,C_LANEPLAYS=1,take={midi=true}},
 {D_POSITION=115,D_LENGTH=3,C_LANEPLAYS=1},
}
local tr={items=items};local reads=0
reaper={
 CountTracks=function()return 17 end,GetTrack=function()return tr end,
 GetTrackName=function()return true,'Guitar'end,GetTrackGUID=function()return 'guid'end,
 GetMediaTrackInfo_Value=function(_,key)return key=='I_NUMFIXEDLANES'and 2 or 0 end,
 CountTrackMediaItems=function(t)return #t.items end,GetTrackMediaItem=function(t,i)return t.items[i+1]end,
 GetMediaItemInfo_Value=function(item,key)return item[key]or 0 end,
 GetActiveTake=function(item)return item.take end,TakeIsMIDI=function(t)return t.midi or false end,
 GetMediaItemTake_Source=function()return {}end,GetMediaSourceNumChannels=function()return 2 end,
 time_precise=function()return 0 end,
 new_array=function(n)local a={};for i=1,n do a[i]=0 end;return a end,
 GetMediaItemTake_Peaks=function(_,rate,start,channels,samples,extra,buf)
  assert(start==105 and channels==2,'Peaks must be requested at absolute project time')
  reads=reads+1;for i=1,samples*2 do buf[i]=.5;buf[samples*2+i]=-.3 end;return samples
 end,
}
local V=dofile(root..'/Scripts/solo_mix_visuals.lua');local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1;print('PASS '..why)end
local data=V.overview(0,{100,120},{start_track=16});local row=data.tracks[1]
check(#data.tracks==1 and data.total_tracks==17,'Pagination reads only the requested tracks')
check(#row.clips==3 and row.hidden==2,'Muted items and inactive lanes are excluded')
check(reads==1 and row.clips[1].start_seconds==105,'Only eligible audio clips request peak data')
check(row.peaks[129]==.5 and row.peaks[1]==0,'Source peaks align to the selected timeline bounds')
check(row.midi==1 and row.clips[2].kind=='midi','MIDI clips are marked without inventing audio peaks')
check(row.unavailable==1 and row.clips[3].kind=='peaks_unavailable','Missing media is not classified as silence')
local nopeaks=reaper.GetMediaItemTake_Peaks
reaper.GetMediaItemTake_Peaks=function()return 0 end
check(V.overview(0,{100,120},{start_track=16}).tracks[1].unavailable==2,'Unavailable caches are explicit')
reaper.GetMediaItemTake_Peaks=nopeaks
check(not pcall(V.overview,0,{100,120},{start_track=-1}),'Negative page offsets are rejected')
check(not pcall(V.overview,0,{100,120},{track_count=17}),'Oversized pages are rejected')
check(not pcall(V.overview,0,{100,120},{start_track=17}),'Out-of-range pages are rejected')
tr.items={};for i=1,300 do tr.items[i]={D_POSITION=105,D_LENGTH=5,C_LANEPLAYS=1}end
local limited=V.overview(0,{100,120},{start_track=16})
check(limited.truncated and limited.tracks[1].truncated and #limited.tracks[1].clips==256,'Large overviews are bounded and explicitly incomplete')
print(checks..' source overview checks passed')
