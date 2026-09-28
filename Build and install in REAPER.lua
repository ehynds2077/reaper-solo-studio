-- Run from REAPER's action list after copying Scripts into its resource folder.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local dest=reaper.GetResourcePath()..'/Scripts/Solo Studio'
local M=dofile(dest..'/solo_core.lua')
local names={'Open recording panel','Record or stop','Another take','Next take','Previous take','Favorite current take','Keep selected passage','Loop four bars','Loop eight bars','Arm recording set','Note current take','Create song project','Tuner'}
local ids={}
for _,name in ipairs(names) do
 local id=reaper.AddRemoveReaScript(true,0,dest..'/Solo Studio - '..name..'.lua',true)
 assert(id~=0,'Could not register '..name)
 ids[name]=id
end
local f=assert(io.open(root..'/Tests/installed-actions.txt','w'))
for _,name in ipairs(names) do f:write(name,'\t',ids[name],'\t',reaper.ReverseNamedCommandLookup(ids[name]),'\n') end
f:close()
local previous=reaper.EnumProjects(-1,'')
for _,template in ipairs({'One instrument','Drums','One person band'}) do
 reaper.Main_OnCommand(41929,0)
 local proj=reaper.EnumProjects(-1,'')
 reaper.GetSetProjectInfo_String(0,'RECORD_PATH','Media',true)
 reaper.GetSetProjectInfo_String(0,'RECORD_FORMAT','evaw',true)
 reaper.Main_OnCommand(40252,0)
 reaper.Main_OnCommand(41745,0)
 reaper.Main_OnCommand(43152,0)
 reaper.Main_OnCommand(41118,0)
 if reaper.GetToggleCommandStateEx(0,42631)==0 then reaper.Main_OnCommand(42631,0) end
 if template=='Drums' then
  M.add_instrument('Drums',{'Kick','Snare','Overhead L','Overhead R'})
 elseif template=='One person band' then
  local vocal=M.add_instrument('Vocals')
  local vocalset=M.get('active')
  M.add_instrument('Guitar')
  M.add_instrument('Bass')
  M.add_instrument('Drums',{'Kick','Snare','Overhead L','Overhead R'})
  M.choose_set(vocalset)
 else M.add_instrument('Vocals') end
 local filename=root..'/Templates/Solo Studio - '..template..'.RPP'
 reaper.Main_SaveProjectEx(proj,filename,8)
 reaper.Main_OnCommand(40860,0)
 -- Use musical pre-roll for recording; a separate count-in would double the wait.
 local input=assert(io.open(filename,'rb'));local data=input:read('*a');input:close()
 data=data:gsub('(<METRONOME )(%d+) (%d+)',function(prefix,flags) return prefix..(tonumber(flags)&~16)..' 2' end,1)
 local output=assert(io.open(filename,'wb'));output:write(data);output:close()
end
reaper.SelectProjectInstance(previous)
if reaper.GetToggleCommandStateEx(0,41819)~=1 then reaper.Main_OnCommand(41819,0) end
reaper.SetExtState(M.ns,'panel_command',tostring(ids['Open recording panel']),true)
local complete=assert(io.open(root..'/Tests/install-status.txt','w'));complete:write('Actions registered; three native templates generated.\n');complete:close()
reaper.Main_OnCommand(ids['Open recording panel'],0)
