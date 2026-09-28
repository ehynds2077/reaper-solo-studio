local dir=debug.getinfo(1,'S').source:sub(2):match('^(.*)/')
dofile(dir..'/solo_action.lua')('Previous take')
