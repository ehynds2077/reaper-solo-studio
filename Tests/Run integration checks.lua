local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
dofile(root..'/Tests/Integration.lua')
