local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/Scripts/')
local out = assert(io.open(root .. '/Tests/reaper-capabilities.txt', 'w'))
out:write('REAPER ', reaper.GetAppVersion(), '\n')
for _, name in ipairs({'GetSetMediaTrackInfo','GetMediaTrackInfo_Value','SetMediaTrackInfo_Value','kbd_enumerateActions','Main_SaveProjectEx','GetAudioAccessorSamples','set_config_var_string','get_config_var_string','SNM_SetDoubleConfigVar','KBD_OnMainActionEx','OscLocalMessageToHost'}) do
  out:write(name, ': ', tostring(reaper.APIExists(name)), '\n')
end
for _,key in ipairs({'projmetrov1','projmetrov2','projmetrof1','projmetrof2','projmetroen','projmetrofn1','projmetrofn2'}) do
  local ok,value=reaper.get_config_var_string(key)
  out:write(key,': ',tostring(ok),' ',value,'\n')
end
out:write('Inputs: ', reaper.GetNumAudioInputs(), '\n')
for i=0,reaper.GetNumAudioInputs()-1 do out:write(i, ': ', reaper.GetInputChannelName(i), '\n') end
local section = reaper.SectionFromUniqueID(0)
local actions = assert(io.open(root .. '/Tests/reaper-actions.tsv','w'))
for i=0,100000 do
  local id,name=reaper.kbd_enumerateActions(section,i)
  if id==0 then break end
  actions:write(id, '\t', name, '\n')
end
actions:close()
out:close()
