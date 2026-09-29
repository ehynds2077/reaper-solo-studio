local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/Tests/')
local real=dofile;local project='song';local transport=0;local busy=false;local buttons={};local played;local stopped=0;local state
local rows={{id='new',title='Newer',status='ready',notes='More bass',created_at=200,duration=180},
 {id='old',title='Older',status='ready',notes='',created_at=100,duration=180}}
local B={list=function()return rows end,vocals=function()return {{name='Vocals',excluded=true}}end,reveal=function()end}
local P={poll=function()end,state=function()return state end,stop=function()stopped=stopped+1;state=nil end,
 play=function(row,variant)assert(transport==0);played=row.id..variant;state={id=row.id,variant=variant,state='playing'}end,
 pause=function()state.state=state.state=='paused'and 'playing'or 'paused'end}
dofile=function(path)if path:match('/solo_bounces.lua$')then return B elseif path:match('/solo_bounce_player.lua$')then return function()return P end else return real(path)end end
reaper={EnumProjects=function()return project end,GetPlayState=function()return transport end,time_precise=function()return 10 end}
gfx={line=function()end}
local V=real(root..'/Scripts/solo_bounces_view.lua')({colors={},text=function()end,color=function()end,busy=function()return busy end,
 run=function(fn)fn()end,button=function(label,x,y,w,h,fn,c,enabled)buttons[label]={run=fn,enabled=enabled~=false}end})
local passed=0;local function check(v,label)assert(v,label);passed=passed+1;print('PASS '..label)end
local function draw()buttons={};V.draw(0,0,1152,382)end
draw();check(buttons['Bounce mix + instrumental'].enabled and buttons['Play full'].enabled,'Export and playback available while stopped')
buttons['Older'].run();draw();buttons['Instrumental'].run();check(played=='oldinstrumental','Selected old version auditions its instrumental')
V.key(32);check(state.state=='paused','Space pauses bounce playback')
V.key(32);check(state.state=='playing','Space resumes bounce playback')
transport=1;draw();check(not buttons['Bounce mix + instrumental'].enabled and not buttons['Play full'].enabled,'Native playback prevents render and overlapping audition')
check(not V.key(32),'Space delegates to native transport when the song is playing')
transport=0;busy=true;draw();check(not buttons['Bounce mix + instrumental'].enabled and not buttons['Open session copy'].enabled,'AI work blocks exports and session switching')
busy=false;rows[2].status='packaging';draw();check(not buttons['Instrumental'].enabled and not buttons['Open session copy'].enabled,'Incomplete archive is not offered as a finished version')
V.close();check(state==nil and stopped>0,'Panel close stops audition')
print(passed..' bounce library controls checks passed')
