-- Model picker with an offline seed and asynchronous public-catalog refresh.
local P={default='openai/gpt-6-luna'}
-- Verified in OpenRouter's tool-capable catalog on 2026-09-27. Refresh replaces
-- this seed with recent leaders from the public API; no rankings are hardcoded.
P.seed={
 {id=P.default,name='OpenAI: GPT-6 Luna'},
 {id='openai/gpt-6-sol',name='OpenAI: GPT-6 Sol'},
 {id='openai/gpt-6-astra',name='OpenAI: GPT-6 Astra'},
 {id='anthropic/claude-opus-5.5',name='Anthropic: Claude Opus 5.5'},
 {id='anthropic/claude-fable-5.1',name='Anthropic: Claude Fable 5.1'},
 {id='google/gemini-3.8-flash',name='Google: Gemini 3.8 Flash'},
 {id='x-ai/grok-4.7',name='SpaceXAI: Grok 4.7'},
 {id='deepseek/deepseek-v4.1-flash',name='DeepSeek: DeepSeek V4.1 Flash'},
}
function P.new(J,R,data,launch)
 local self={busy=false,started=false};local path=data..'/models.json';local deadline
 local function read()
  local ok,v=pcall(J.read,path);return ok and type(v)=='table'and v or {}
 end
 local cache=read()
 function self.rows()
  local rows=type(cache.models)=='table'and #cache.models>0 and cache.models or P.seed
  local result={}
  for _,row in ipairs(rows)do if type(row.id)=='string'and type(row.name)=='string'then result[#result+1]=row end end
  return result
 end
 function self.selected(id)
  for _,row in ipairs(self.rows())do if row.id==id then return row end end
  return {id=id,name=id}
 end
 function self.price(id)
  local row=self.selected(id)
  if type(row.input_per_million)=='number'and type(row.output_per_million)=='number'then
   return string.format('Catalog: $%g / $%g per 1M (in / out)',row.input_per_million,row.output_per_million)
  end
  return 'Refresh models for current prices'
 end
 function self.refresh()
  if self.busy then return end
  self.busy=true;self.started=true;deadline=R.time_precise()+40
  -- Dedicated result file avoids mistaking an old cache for completed work.
  -- The worker clears pending on either success or failure.
  J.write(data..'/models-refresh.json',{models=cache.models,updated=cache.updated,pending=true})
  local ok,err=pcall(launch,{'--models',data..'/models-refresh.json'})
  if not ok then self.busy=false;cache.error='Could not start the model refresh worker.';error(err)end
 end
 function self.ensure()
  if not self.started then
   self.started=true
   if type(cache.updated)~='number'or os.time()-cache.updated>86400 or
    (cache.models and cache.models[1]and cache.models[1].image_input==nil)then self.refresh()end
  end
 end
 function self.poll()
  if not self.busy then return end
  local ok,v=pcall(J.read,data..'/models-refresh.json')
  if ok and type(v)=='table'and not v.pending then
   cache=v;self.busy=false;J.write(path,cache)
  elseif R.time_precise()>deadline then self.busy=false;cache.error='Model refresh timed out. Your saved choices are still available.'end
 end
 function self.message()return cache.error end
 function self.menu(current)
  local rows=self.rows();local labels={};local ids={};local present=false
  for _,row in ipairs(rows)do
   local label=row.name..(row.id==P.default and ' (default)'or '')
   if row.image_input==true then label=label..' · vision'elseif row.image_input==false then label=label..' · numbers only'end
   if type(row.input_per_million)=='number'and type(row.output_per_million)=='number'then
    label=label..string.format(' — $%g / $%g per 1M',row.input_per_million,row.output_per_million)
   end
   labels[#labels+1]=(row.id==current and '!'or '')..label:gsub('[|#!<>\r\n]',' ');ids[#ids+1]=row.id
   present=present or row.id==current
  end
  if not present then labels[#labels+1]='!Current: '..current:gsub('[|#!<>\r\n]',' ');ids[#ids+1]=current end
  labels[#labels+1]='Enter model ID…';ids[#ids+1]=false
  local index=gfx.showmenu(table.concat(labels,'|'))
  if index==#labels then
   local ok,value=R.GetUserInputs('Custom OpenRouter model',1,'Model ID:,extrawidth=220',current)
   if ok then
    assert(value:match('^[%w_%.~%-]+/[%w_%.:%-]+$'),'Enter an OpenRouter model ID with tool support.')
    return value
   end
  elseif index>0 then return ids[index]end
 end
 return self
end
return P
