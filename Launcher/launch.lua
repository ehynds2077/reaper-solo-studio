-- Run by REAPER's command-line ReaScript support. No project/transport changes.
local R=reaper;local ns='SoloStudio_v1'
if R.GetExtState(ns,'panel_open')=='1'then
 R.SetExtState(ns,'panel_raise','1',false)
 return
end
local script=R.GetResourcePath()..'/Scripts/Solo Studio/Solo Studio - Open recording panel.lua'
local f=io.open(script,'rb')
if not f then R.ShowMessageBox('Install the Solo Studio scripts in REAPER before opening the desktop launcher.','Solo Studio',0);return end
f:close()
local command=R.AddRemoveReaScript(true,0,script,true)
if command==0 then R.ShowMessageBox('REAPER could not load the Solo Studio panel.','Solo Studio',0);return end
R.Main_OnCommand(command,0)
