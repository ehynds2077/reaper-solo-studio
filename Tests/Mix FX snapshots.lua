-- Snapshot boundaries and transactional restoration without a running REAPER.
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local first='BYPASS 0 0 0\n<VST "Existing"\nopaque-a\nAAAQAAAA\n>\nFXID {A}\n<PARMENV 0\nACT 1\nPT 0 0.25 0\n>\nWAK 0 0\n'
local second='BYPASS 1 1 0\n<JS "Other"\n0 1 2 3\n>\nFXID {B}\nWAK 0 0\n'
local prefix='<TRACK\nVOLPAN 1 0\n<FXCHAIN\nSHOW -1\nLASTSEL 0\n'
local suffix='>\n<ITEM\nPOSITION 3\n<SOURCE WAVE\nFILE "untouched.wav"\n>\n>\n>\n'
local t={chunk=prefix..first..second..suffix};local other={chunk=prefix..first..suffix};local writes=0;local fail=false
reaper={GetTrackStateChunk=function(tr)return true,tr.chunk end,
 SetTrackStateChunk=function(tr,chunk)writes=writes+1;tr.chunk=chunk;if fail and writes==2 then return false end;return true end}
local F=dofile(root..'/Scripts/solo_mix_effects.lua');local n=0
local function check(ok,label)assert(ok,label);n=n+1;print('PASS '..label)end
check(F.capture(t,'{A}')==first and F.capture(t,'{B}')==second,'Capture includes plugin payload, offline/bypass and automation without neighboring FX/media')
local changed=first:gsub('opaque%-a','edited-a'):gsub('ACT 1','ACT 0')
F.apply({F.plan(t,{['{A}']=changed})})
check(t.chunk==prefix..changed..second..suffix,'Restore modifies only the selected effect block')
check(not F.same(first,changed),'Parameters and automation changes remain significant')
check(F.same(first,first:gsub('AAAQAAAA','AFByb2dyYW0gMQAQAAAA')),'REAPER default program-name canonicalization is equivalent')
check(not F.same(first,first:gsub('opaque%-a','opaque-b')),'Opaque plugin payload is never discarded')
check(F.same(first,first:gsub('FXID','FLOAT 1 2 3 4\nFXID')),'Window state is ignored for conflict detection')
local before=t.chunk;local before_other=other.chunk;writes=0;fail=true
check(not pcall(F.apply,{F.plan(t,{['{A}']=first}),F.plan(other,{['{A}']=changed})}),'A failed restore reports an error')
check(t.chunk==before and other.chunk==before_other,'Failure rolls back every touched track')
fail=false;writes=0
check(not pcall(F.plan,t,{['{A}']=second})and writes==0,'Mismatched snapshot GUID rejected before writes')
check(not pcall(F.capture,t,'{missing}'),'Deleted existing effect is reported rather than recreated')
print(n..' FX snapshot checks passed')
