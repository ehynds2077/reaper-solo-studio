-- Launch the installed action once; repeated opens only raise its living panel.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local passed=0;local function check(v,name)assert(v,name);passed=passed+1;print('PASS '..name)end
local ext,starts,registered,errors={},0,0,0
local exists,command=true,123
local R={GetExtState=function(_,key)return ext[key]or ''end,
 SetExtState=function(_,key,value,persist)assert(not persist);ext[key]=value end,
 GetResourcePath=function()return '/test resource'end,
 AddRemoveReaScript=function(add,section,path,commit)
  assert(add and section==0 and commit and path=='/test resource/Scripts/Solo Studio/Solo Studio - Open recording panel.lua')
  registered=registered+1;return command
 end,
 Main_OnCommand=function(id)assert(id==123);starts=starts+1;ext.panel_open='1'end,
 ShowMessageBox=function()errors=errors+1 end}
local env=setmetatable({reaper=R,io={open=function(path)
 assert(path=='/test resource/Scripts/Solo Studio/Solo Studio - Open recording panel.lua')
 return exists and {close=function()end}or nil
end}},{__index=_G})
local function launch()assert(loadfile(root..'/Launcher/launch.lua','t',env))()end
launch();check(starts==1 and registered==1,'Closed panel launches its registered REAPER action')
launch();check(starts==1 and registered==1 and ext.panel_raise=='1','Existing panel is raised without duplicate action or termination prompt')
ext.panel_open='';launch();check(starts==2,'Panel can launch again after closing')
ext.panel_open='';exists=false;launch();check(starts==2 and errors==1,'Missing installation reports an error without launching anything')
exists=true;command=0;launch();check(starts==2 and errors==2,'Registration failure reports an error')
print(passed..' desktop launcher checks passed')
