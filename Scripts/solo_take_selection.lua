-- View-local take selection, shared by Timeline and Takes. Keys survive lane insertion.
return function()
 local Q={};local keys,focus,anchor={},nil,nil;local automatic=true
 function Q.reset()keys={};focus=nil;anchor=nil;automatic=true end
 function Q.only(key)
  keys={};if key then keys[key]=true end
  focus=key;anchor=key;automatic=false
 end
 function Q.has(key)return keys[key]==true end
 function Q.replace(rows)
  Q.only(nil)
  for _,row in ipairs(rows)do keys[row.key]=true;focus=focus or row.key end
  anchor=focus
 end
 function Q.rows(rows)
  local selected={};for _,row in ipairs(rows)do if keys[row.key]then selected[#selected+1]=row end end
  return selected
 end
 function Q.chosen(rows)
  local first
  for _,row in ipairs(rows)do if keys[row.key]then if row.key==focus then return row end;first=first or row end end
  return first
 end
 function Q.sync(rows)
  local visible={};for _,row in ipairs(rows)do visible[row.key]=true end
  local had=next(keys)~=nil
  for key in pairs(keys)do if not visible[key]then keys[key]=nil end end
  if not visible[anchor]then anchor=nil end
  if not keys[focus]then focus=nil end
  if not next(keys)and (automatic or had)then
   local row=rows[1];for _,r in ipairs(rows)do if r.playing then row=r;break end end
   if row then Q.only(row.key)end
  end
  local row=Q.chosen(rows);focus=row and row.key
 end
 function Q.click(rows,key,add,range)
  Q.sync(rows)
  local index,base
  for i,row in ipairs(rows)do if row.key==key then index=i end;if row.key==(anchor or focus)then base=i end end
  if not index then return end
  if range then
   base=base or index;anchor=rows[base].key
   if not add then keys={}end
   for i=math.min(base,index),math.max(base,index)do keys[rows[i].key]=true end
   focus=key;automatic=false
  elseif add then
   keys[key]=not keys[key]or nil;anchor=key;automatic=false
   if keys[key]then focus=key elseif focus==key then focus=nil end
   local row=Q.chosen(rows);focus=row and row.key
  else Q.only(key)end
 end
 function Q.neighbor_after_delete(before,removed)
  local gone={};for _,row in ipairs(removed)do gone[row.key]=true end
  local index=1;for i,row in ipairs(before)do if row.key==focus then index=i;break end end
  local neighbor
  for i=index+1,#before do if not gone[before[i].key]then neighbor=before[i].key;break end end
  if not neighbor then for i=index-1,1,-1 do if not gone[before[i].key]then neighbor=before[i].key;break end end end
  return neighbor
 end
 function Q.after_delete(before,removed)Q.only(Q.neighbor_after_delete(before,removed))end
 return Q
end
