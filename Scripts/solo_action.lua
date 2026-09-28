local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
local M=dofile(dir..'/solo_core.lua')
local function current()
 local rows=M.lanes();for _,row in ipairs(rows) do if row.playing then return row end end
 error('Audition a take in Solo Studio first.',0)
end
local actions={
 ['Record or stop']=M.record,
 ['Another take']=M.another,
 ['Next take']=function()M.step(1) end,
 ['Previous take']=function()M.step(-1) end,
 ['Favorite current take']=function()M.favorite(current().lane) end,
 ['Keep selected passage']=function()M.comp(current().lane) end,
 ['Loop four bars']=function()M.loop_bars(4) end,
 ['Loop eight bars']=function()M.loop_bars(8) end,
 ['Arm recording set']=M.arm,
 ['Note current take']=function()
  local row=current();local ok,note=reaper.GetUserInputs('Take note',1,'Your note:,extrawidth=320',row.note)
  if ok then M.note(row.lane,note) end
 end,
 ['Create song project']=function()
  reaper.Main_OnCommand(41929,0)
  reaper.Main_openProject('template:'..reaper.GetResourcePath()..'/ProjectTemplates/Solo Studio - One person band.RPP')
 end,
 ['Tuner']=function()
  dofile(dir..'/solo_tuner.lua').open()
 end,
}
return function(name)
 local ok,err=pcall(assert(actions[name],'Unknown Solo Studio action'))
 if not ok then M.message(tostring(err):match('^[^\n]+')) end
end
