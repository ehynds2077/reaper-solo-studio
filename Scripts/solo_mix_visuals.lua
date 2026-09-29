-- Read-only source peak overview. Never renders audio or changes items/lanes.
local R=reaper
local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local J=dofile(dir..'/solo_json.lua')
local V={}
function V.overview(project,bounds,args)
 local first=args.start_track or 0;local count=args.track_count or 16
 assert(type(first)=='number'and first%1==0 and first>=0,'Track offset must be a nonnegative integer')
 assert(type(count)=='number'and count%1==0 and count>=1 and count<=16,'Request 1–16 tracks')
 local total=R.CountTracks(project);assert(first<total,'Track offset exceeds project tracks')
 local rows=J.array();local bins=512;local step=(bounds[2]-bounds[1])/bins
 local started=R.time_precise();local scanned=0;local truncated=false
 for index=first,math.min(total-1,first+count-1)do
  local tr=R.GetTrack(project,index);local _,name=R.GetTrackName(tr)
  local row={id=R.GetTrackGUID(tr),name=name,muted=R.GetMediaTrackInfo_Value(tr,'B_MUTE')~=0,
   clips=J.array(),peaks=J.array(),unavailable=0,midi=0,hidden=0,truncated=false}
  for n=1,bins do row.peaks[n]=0 end
  local fixed=R.GetMediaTrackInfo_Value(tr,'I_NUMFIXEDLANES')>0
  for n=0,R.CountTrackMediaItems(tr)-1 do
   if scanned>=2000 or R.time_precise()-started>3 then row.truncated=true;truncated=true;break end
   scanned=scanned+1
   local item=R.GetTrackMediaItem(tr,n)
   local pos=R.GetMediaItemInfo_Value(item,'D_POSITION')
   local left=math.max(pos,bounds[1]);local right=math.min(pos+R.GetMediaItemInfo_Value(item,'D_LENGTH'),bounds[2])
   local lane=R.GetMediaItemInfo_Value(item,'C_LANEPLAYS')
   if right>left and R.GetMediaItemInfo_Value(item,'B_MUTE')==0 and lane~=-1 and (not fixed or lane>0)then
    if #row.clips>=256 then row.truncated=true;truncated=true;break end
    local clip={start_seconds=left,end_seconds=right,kind='peaks_unavailable'}
    local take=R.GetActiveTake(item)
    if take and R.TakeIsMIDI(take)then clip.kind='midi';row.midi=row.midi+1
    elseif take and R.GetMediaItemInfo_Value(item,'B_ALLTAKESPLAY')~=1 then
     local source=R.GetMediaItemTake_Source(take)
     local channels=source and math.min(2,R.GetMediaSourceNumChannels(source))or 0
     if channels>0 then
      local samples=math.max(1,math.min(bins,math.ceil((right-left)/step)))
      local buf=R.new_array(samples*channels*2)
      local received=R.GetMediaItemTake_Peaks(take,1/step,left,channels,samples,0,buf)&0xfffff
      if received>0 then
       clip.kind=received==samples and 'audio'or 'partial_peaks'
       for i=0,math.min(received,samples)-1 do
        local peak=0
        for ch=1,channels do
         peak=math.max(peak,math.abs(buf[i*channels+ch]),math.abs(buf[samples*channels+i*channels+ch]))
        end
        local bin=math.min(bins,math.floor((left-bounds[1]+i*step)/step)+1)
        if peak==peak and peak<math.huge then row.peaks[bin]=math.max(row.peaks[bin],peak)end
       end
      end
     end
    end
    if clip.kind=='peaks_unavailable'or clip.kind=='partial_peaks'then row.unavailable=row.unavailable+1 end
    row.clips[#row.clips+1]=clip
   elseif right>left then row.hidden=row.hidden+1 end
  end
  rows[#rows+1]=row
 end
 return {bounds=bounds,tracks=rows,total_tracks=total,start_track=first,
  next_track=first+#rows<total and first+#rows or J.null,truncated=truncated,
  scope='Source peak overview, each track scaled independently. Active lanes/unmuted items only. No track FX, fader or master processing. Unavailable peaks are NOT silence; MIDI and routing may produce audio.'}
end
return V
