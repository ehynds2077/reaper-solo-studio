-- Native project tempo and metronome controls; no audio tracks or plug-ins added.
local R=reaper
local T={min_bpm=20,max_bpm=300}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
function T.bpm() return R.Master_GetTempo() end
function T.tempo_enabled()
  return R.GetPlayState() & 4 == 0 and R.CountTempoTimeSigMarkers(0)==0
end
function T.set_bpm(value)
  if R.GetPlayState() & 4 ~= 0 then error('Finish recording before changing tempo.',0) end
  if R.CountTempoTimeSigMarkers(0)>0 then error('This song has a tempo map. Edit its tempo markers in REAPER.',0) end
  if not finite(value) or value<T.min_bpm or value>T.max_bpm then error('Enter a tempo from 20 to 300 BPM.',0) end
  R.SetCurrentBPM(0,value,true)
end
function T.click_db()
  local ok,value=R.get_config_var_string('projmetrov1')
  value=ok and tonumber(value)
  if not value then return nil end
  return value<=0 and -math.huge or 20*math.log(value,10)
end
function T.volume_position()
  local db=T.click_db()
  if not db or db==-math.huge then return 0 end
  return math.max(0,math.min(1,R.DB2SLIDER(db)/R.DB2SLIDER(0)))
end
function T.position_db(position)
  return position<=0 and -math.huge or R.SLIDER2DB(position*R.DB2SLIDER(0))
end
function T.format_db(db)
  if not db then return 'Settings...' end
  return db==-math.huge and 'Muted' or string.format('%.1f dB',db)
end
function T.set_volume(position)
  if not finite(position) or position<0 or position>1 then error('Click volume is outside its slider range.',0) end
  if not R.APIExists('OscLocalMessageToHost') or T.click_db()==nil then error('Open Click sound to adjust the native metronome volume.',0) end
  R.Undo_BeginBlock2(0)
  -- REAPER's default OSC mapping invokes the native metronome-volume action.
  -- Its fader uses the same DB2SLIDER scale as the native metronome dialog.
  R.OscLocalMessageToHost('/action/999/cc',position*R.DB2SLIDER(0)/1000)
  R.MarkProjectDirty(0)
  R.Undo_EndBlock2(0,'Solo Studio: click volume',-1)
end
function T.set_click_db(db)
  if not finite(db) or db < -60 or db>0 then error('Enter click volume from -60 to 0 dB, or use the slider to mute.',0) end
  T.set_volume(R.DB2SLIDER(db)/R.DB2SLIDER(0))
end
function T.sound_settings() R.Main_OnCommand(40363,0) end
return T
