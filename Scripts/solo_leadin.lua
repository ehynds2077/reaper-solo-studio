-- Dim playback hardware sends during musical pre-roll. The native click has
-- its own hardware route; input recording gain and track faders are untouched.
local R=reaper
local D={ns='SoloStudio_v1',key='leadin.outputs',gain=10^(-6/20)}
local function track(project,guid)
 if guid=='master'then return R.GetMasterTrack(project)end
 for i=0,R.CountTracks(project)-1 do local tr=R.GetTrack(project,i);if R.GetTrackGUID(tr)==guid then return tr end end
end
function D.restore(project,token)
 if not R.ValidatePtr(project,'ReaProject*')then return end
 local _,value=R.GetProjExtState(project,D.ns,D.key)
 local owner=value:match('^([^\n]+)')
 if not owner or token and owner~=token then return end
 for line in value:gmatch('[^\n]+')do
  local guid,i,src,dst,original,applied=line:match('^([^\t]+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$')
  if guid then
   local tr=track(project,guid);i=tonumber(i);original=tonumber(original);applied=tonumber(applied)
   if tr and original and applied and i<R.GetTrackNumSends(tr,1)
    and R.GetTrackSendInfo_Value(tr,1,i,'I_SRCCHAN')==tonumber(src)
    and R.GetTrackSendInfo_Value(tr,1,i,'I_DSTCHAN')==tonumber(dst)then
    local current=R.GetTrackSendInfo_Value(tr,1,i,'D_VOL')
    -- Preserve intentional manual gain/routing changes made during the lead-in.
    if math.abs(current-applied)<0.0000001 then R.SetTrackSendInfo_Value(tr,1,i,'D_VOL',original)end
   end
  end
 end
 R.SetProjExtState(project,D.ns,D.key,'')
end
function D.begin(project,token,punch)
 if not punch or punch<=0 then return end
 D.restore(project)
 local lines={token};local outputs={}
 for n=-1,R.CountTracks(project)-1 do
  local tr=n==-1 and R.GetMasterTrack(project)or R.GetTrack(project,n)
  for i=0,R.GetTrackNumSends(tr,1)-1 do
   local original=R.GetTrackSendInfo_Value(tr,1,i,'D_VOL');local applied=original*D.gain
   outputs[#outputs+1]={tr=tr,i=i,value=applied}
   lines[#lines+1]=table.concat({n==-1 and 'master'or R.GetTrackGUID(tr),i,
    R.GetTrackSendInfo_Value(tr,1,i,'I_SRCCHAN'),R.GetTrackSendInfo_Value(tr,1,i,'I_DSTCHAN'),
    string.format('%.17g',original),string.format('%.17g',applied)},'\t')
  end
 end
 -- Save recovery data before applying any temporary gain change.
 R.SetProjExtState(project,D.ns,D.key,table.concat(lines,'\n'))
 for _,out in ipairs(outputs)do R.SetTrackSendInfo_Value(out.tr,1,out.i,'D_VOL',out.value)end
end
function D.recover(project)
 if R.GetPlayStateEx(project)&4==0 then D.restore(project)end
end
return D
