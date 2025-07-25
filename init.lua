show_more = false

simple_targeting = true

bindkey = [^D] CMD_LUA_CONSOLE

macros += M 1 ===cast_1
macros += M 2 ===cast_2
macros += M 3 ===cast_3
macros += M 4 ===cast_4
macros += M g zaf

{
-- spells autocast when you press numbers 1-4
-- it will select and cast a spell bound to any letter in the corresponding entry of castmacros
-- if an entry begins with ~ it is instead a macro
-- you can inscribe your weapon or first ring with a different castmacros string
-- the castmacros string begins with a /. You can put other inscriptions before the /.
local castmacros = "/~zb,~zc,abcdefghijk,ABCDEFGHIJK"

local monster_array
local flamewave_start_turn=0
local flamewave_last_turn=0
local monster_ac
-- maps (spell name with optional modifier) .. x .. "," .. y to damage_value
-- so we don't have to recalculate it
local mondam_cache = {}
local acmus2_cache = {}
local LOS = 7

-- look at https://github.com/crawl/crawl/blob/0.31.0/crawl-ref/source/l-moninf.cc
--

-- for some reason crawl.do_commands({"CMD_WAIT"}) does not work for this
function wait()
  crawl.sendkeys(".")
  crawl.process_command()
end

function has_value(tab, val)
  for index, value in ipairs(tab) do
    if value == val then
      return true
    end
  end

  return false
end

function mysplit(inputstr, sep)
  local t = {}
  for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
    table.insert(t, str)
  end
  return t
end

function cast_1()
  cast_letters(1)
end

function cast_2()
  cast_letters(2)
end

function cast_3()
  cast_letters(3)
end

function cast_4()
  cast_letters(4)
end

function cast_letters(index)
  local weapon = items.equipped_at(1,1)
  local ring = items.equipped_at("ring",1)
  local insc
  if weapon ~= nil and weapon.inscription ~= nil and string.find(weapon.inscription, "/") then
    insc = weapon.inscription
  elseif ring ~= nil and ring.inscription ~= nil and string.find(ring.inscription, "/") then
    insc = ring.inscription
  else
    insc = castmacros
  end
  
  insc = string.sub(insc, string.find(insc, "/") + 1)
  bpr("castmacros = /" .. insc)
  
  local t = mysplit(insc, ",")
  letters = t[index]
  if letters ~= nil then
    if string.sub(letters, 1, 1) == "~" then
      -- it's macro keys
      bpr("Processing macro " .. letters)
      crawl.process_keys(string.sub(letters, 2))
      return
    else
      bpr("Autocasting spells bound to " .. letters)
      cast_appropriate_spell(true, false, letters)
    end
  end
end

function initialize_monster_array()
  monster_array = {}
  local x
  for x = -LOS-5,LOS+5 do
    monster_array[x] = {}
  end
  mondam_cache = {}
end

function update_monster_array()
  local x,y
  for x = -LOS,LOS do
    for y = -LOS,LOS do
      monster_array[x][y] = monster.get_monster_at(x, y)
    end
  end
end

local max_spellpower_table = {foxfire=25, shock=25, ["flame wave"]=100, ["stone arrow"]=50, scorch=50, ["poisonous vapours"]=50, ["iskenderun's mystic blast"]=100}

function spellpower(spellname)
  local maxPower = 200
  local low_power = max_spellpower_table[spellname]
  if low_power ~= nil then
    maxPower = low_power
  end
  return spells.power_perc(spellname) * maxPower / 100.0
end

function can_target(x, y)
  return you.see_cell_no_trans(x, y)
end

function can_smite(x, y)
  return you.see_cell_no_trans(x, y) and not is_wall(x, y)
end

function valid_enemy(x, y)
  m = monster_array[x][y]
  if m ~= nil then
    return m and m:attitude() == 0 and you.see_cell_no_trans(x, y) and not m:is_firewood()
  end
  return false
end


function valid_enemy_explosion(m, x, y, x2, y2)
  return m and m:attitude() == 0 and not m:is_firewood() and view.cell_see_cell(x, y, x2, y2)
end

function spell_cost(spellname)
  if spellname == "flame wave" then
    if flamewave_turns() > 0 then
      return 1
    else
      return 3 -- because it will cost less later on and we probably won't just do 1 cast
    end
  end
  return spells.mana_cost(spellname)
end

-- a number indicating how urgent it is that we kill monsters quickly vs efficiently
-- unused at present
function danger()
  local x,y
  local danger=0
  -- any dangerous monsters within 2 squares?
  for x=-2,2 do
    for y=-2,2 do
      if valid_enemy(x, y) then
        local m = monster_array[x][y]
        if m:threat() >= 2 then
          danger = danger + m:threat()
        end
      end
    end
  end
  -- count dangerous monsters in LOS
  -- 3 make the overall situation dangerous
  for x=-7,7 do
    for y=-7,7 do
      if valid_enemy(x, y) then
        local m = monster_array[x][y]
        if m:threat() >= 2 then
          danger = danger + 0.7
        end
      end
    end
  end
  return danger
end

-- argmax_x (f(x)) for x in t
function table_max_by(t, f)
  if #t == 0 then
    return nil
  end
  local best = f(t[1])
  local bestIx = 1
  for i=1,#t do
    local value = f(t[i])
    if value > best then
      best = value
      bestIx = i
    end
  end
  return t[bestIx]
end

-- score a value_table entry by efficiency
function efficiency(x, minDamage)
  local continuingFlameWave = (x == "flame wave" and flamewave_turns() > 0)
  if x[1] < minDamage and not continuingFlameWave then
    return 0 -- even if it's efficient we want to deal decent damage
    -- but don't interrupt an ongoing flame wave so much
  end
  return x[1] / spell_cost(x[2])
end

local spelltable

function targetSpell(spellname, x, y, noTarget)
  letter = spells.letter(spellname)
  if letter == nil then
    return
  end
  if noTarget then
    crawl.process_keys("Z" .. letter)
    return
  end
  target = ""
  if x == 0 and y == 0 then
    target = ""
  else
    target = "r"
  end
  if x < 0 then
    target = target .. string.rep("h", -x)
  else
    target = target .. string.rep("l", x)
  end
  if y < 0 then
    target = target .. string.rep("k", -y)
  else
    target = target .. string.rep("j", y)
  end
  bpr("Z" .. letter .. target .. "f")
  crawl.process_keys("Z" .. letter .. target .. "f", true)
end

function evaluate_spell(spellname, spellkeys)
  if not castable(spellname) then
    return {0, spellname, 0, 0}
  end
  letter = spells.letter(spellname)
  if letter == nil then
    return {0, spellname, 0, 0}
  end
  if spellkeys ~= nil and not string.find(spellkeys, spells.letter(spellname)) then
    return {0, spellname, 0, 0}
  end

  local t = spelltable[spellname]()
  return {t[1] * (1 - spells.fail(spellname)/100.0), t[2], t[3], t[4]}
end

function cast_appropriate_spell(efficient, quiet, spellkeys)
  initialize_monster_array()
  update_monster_array()
  LOS = you.los()
  local value_table = {}

  local noTargetSpells = {"arcjolt", "foxfire", "iskenderun's mystic blast", "irradiate"}
  local loudspells = {"fireball", "ignition", "fire storm", "lee's rapid deconstruction"}
  for spell, f in pairs(spelltable) do
    if not quiet or not has_value(loudspells, spell) then
      table.insert(value_table, evaluate_spell(spell, spellkeys))
    end
  end
  
  if efficient then
    
    local bestDmg = table_max_by(value_table, function (x) return x[1] end)[1]
    local bestEfficiency = table_max_by(value_table, function (x) return efficiency(x, bestDmg / 2) end)
    table.sort(value_table, function (k1, k2) return efficiency(k1, bestDmg / 2) < efficiency(k2, bestDmg / 2) end)
  else
    table.sort(value_table, function (k1, k2) return k1[1] < k2[1] end)
  end

  local best = value_table[#value_table]

  local i
  for i = 1,#value_table do
    if value_table[i][1] ~= 0 then
      local loc = ""
      if value_table[i][3] ~= 0 or value_table[i][4] ~= 0 then
        loc = "@" .. value_table[i][3] .. "," .. value_table[i][4]
      end
      local desc = value_table[i][2] .. loc .. ": damage value " .. math.floor(value_table[i][1]) .. "| MP efficiency " .. math.floor(value_table[i][1]/spell_cost(value_table[i][2]))
      crawl.mpr(desc)
    end
  end

  if best[2] == "flame wave" then
    if flamewave_turns() > 0 then
      crawl.mpr("continuing flame wave")
      flamewave_last_turn = you.turns()
      wait()
      return
    end
    flamewave_start_turn = you.turns()
    flamewave_last_turn = you.turns()
  end


  if best[1] > 2 then
    if best[2] == "lee's rapid deconstruction" then
      cast_lrd(best[3], best[4])
    else
     targetSpell(best[2], best[3], best[4], has_value(noTargetSpells, best[2]))
      -- spells.cast(best[2], best[3], best[4])
    end
  end
end

function resisted_damage(dmg, res)
  if res == 0 then
    return dmg
  end
  if res <= -1 then
    return dmg*1.5
  end
  if res == 1 then
    return dmg * 0.5
  end
  if res == 2 then
    return 0 -- don't even bother
    -- return dmg * 0.2
  end
  if res == 3 then
    return 0
  end
  return 0
end


function guess_ac(m)
  local ac_pips = m:ac()
  -- pips is ceil(mi->ac/5.0) from l-moninfo.cc
  if ac_pips == 0 then
    return 0
  end
  if monster_ac[m:name()] ~= nil then
    if math.ceil(monster_ac[m:name()] / 5.0) == ac_pips then
      return monster_ac[m:name()]
    end
  end
  return 2.5 + (ac_pips - 1) * 5
end

-- damage against ac assuming damage is uniformly chosen between 0 and dam
function ac_damage_linear(dam, m)
  local ac = guess_ac(m)
  local mad = min(ac, dam)
  local numerator = mad * dam*dam*0.5 - mad*mad*dam*0.5 + mad*mad*mad/6.0
  local denom = dam*dam*0.5*ac
  return dam * numerator / denom
end

-- sum vectors
function sv(v1, v2)
  local v3, i
  for i=1,#v1 do
    v3[i] = v1[i] + v2[i]
  end
  return v3
end

-- a number indicating how important it is to deal dmg damage to this enemy
-- TODO: being close increases danger
-- TODO: certain enemy types can be prioritized:  floating eyes are always max danger
-- shining eyes, ghost moths
function damage_value(spell_context, dmg, m, kill_bonus)
  if m == nil then
    crawl.mpr("nil m in damage value")
  end
  local mhp = string.gsub(m:max_hp(), "about ", "")
  mhp = string.gsub(mhp, "~", "")
  mhp = tonumber(mhp)
  local hp = mhp * (6 - m:damage_level())/6.0 + 1
  local kill_value = m:threat() + 1
  if dmg > hp * 1.2 then
    dmg = hp * 2
  end
  local multiplier = 100
  if summoned_monster(m) then
    multiplier = 20
  end
  if m:is_safe() then
    multiplier = 10
  end
  local result = (dmg * kill_value / hp + dmg * kill_value / mhp) * multiplier
  if spell_context ~= nil then
    mondam_cache[spell_context .. "|" .. m:x_pos() .. "," .. m:y_pos()] = result
  end
  return result
end

function total_damage_value()
  local x,y
  local totValue = 0
  for x=-LOS,LOS do
    for y=-LOS,LOS do
      if valid_enemy(x, y) then
        totValue = totValue + damage_value(nil, 10000, monster_array[x][y])
      end
    end
  end
  return totValue
end

-- NdM damage against ac
-- guess ac based on monster
function ac_damage_NdM(N, M, m)
  local ac = guess_ac(m)
  return ac_damage_NdM_ac(N, M, ac)
end

-- NdM damage against ac
-- specify ac
function ac_damage_NdM_ac(N, M, ac)
  local var_NdM = N * (M^2 - 1) / 12.0
  local mean_NdM = N * (M + 1) / 2.0

  return ac_damage_mus2(mean_NdM, var_NdM, ac)
end

-- AC damage if the damage is normally approximated with mean mu
-- and variance s2
function ac_damage_mus2(mu, s2, ac)
  local cached = acmus2_cache[mu .. "," .. s2 .. "," .. ac]
  if cached then
    return cached
  end

  -- we'll crudely model this with ((3d2) + A) * B
  -- such that it has the same mean and variance
  -- mean of ((3d2) + A)*B is
  -- (3*3/2 + A) * B = mu
  -- var of ((3d2) + A)*B is
  -- B*B*3*(2*2-1)/12 = s2
  local B = math.sqrt(s2/0.75)
  local A = mu / B - 3 * 3 / 2
  local i, j, k, a
  local tdam = 0
  for i=1,2 do
    for j=1,2 do
      for k=1,2 do
        local d = ((i + j + k) + A) * B
        if d > ac then
          -- (sum_a=0^ac d-a) / (ac+1)
          -- = (sum_a=0^ac d - sum_a=0^ac a) / (ac+1)
          -- = (d(ac+1) - ac(ac+1)/2) / (ac+1)
          -- = d - ac/2
          tdam = tdam + d - ac/2
        else
          -- (sum_a=0^d d-a) / (ac+1) + (sum_a=d+1^ac 0) / (ac + 1)
          -- = ((sum_a=0^d d) - (sum_a=0^d a))/(ac+1)
          -- = (d(d+1) - d(d+1)/2)/(ac+1)
          tdam = tdam + (d*(d+1)/2) / (ac+1)
        end
        -- for a=0,ac do
        --   local d = 
        --   if d > a then
        --     tdam = tdam + d - a
        --   end
        -- end
      end
    end
  end
  local result = tdam / (2*2*2)
  acmus2_cache[mu .. "," .. s2 .. "," .. ac] = result
  return result
end

-- just ask if it has a shield or not
-- can't be bothered to figure out the actual sh value
--  (though it would be possible based on monster HD and shield description)
-- if it has a shield just assume 50% block chance
function sh_damage(dmg, m)
  local d = m:target_desc()
  -- could be a buckler but then it probably wouldn't be 50% block chance so w/e
  local has_shield = string.find(d, "shield")
  if has_shield then
    return dmg * 0.5
  end
  return dmg
end

function summoned_monster(m)
  local d = m:target_desc()
  if string.find(d, "summoned") then
    return true
  end
  return false
end

-- a friendly monster that isn't you
function friendly_at(x, y)
  local m = monster_array[x][y]
  if m ~= nil then
    if m:attitude() > 0 and m:name() ~= "battlesphere" and m:name() ~= "orb of destruction" then
      return true -- neutral or friendly monster, not a battlesphere
    end
  end
  return false
end

-- is this beam blocked by an obstacle, so that we'd get an error if we tried to target?
function blocked_beam(path)
  local i
  for i=1,#path do
    if firewood_at(path[i][1], path[i][2]) then
      return true
    end
  end
  return false
end

-- a monster that blocks targeting for fireball
function firewood_at(x, y)
  local m = monster_array[x][y]
  if m ~= nil then
    return m:is_firewood()
  end
  return false
end

function fireball_damage_at_target(x, y, N, M, avoidPlayer)
  local totDmg = 0
  -- 3d(3.33+Power/6)
  local x2, y2
  for x2 = -1, 1 do
    for y2 = -1, 1 do
      local m = monster_array[x+x2][y+y2]
      if valid_enemy_explosion(m, x+x2, y+y2, x, y) then
        local dmg = mondam_cache["fireball|" .. (x+x2) .. "," .. (y+y2)] or damage_value("fireball", resisted_damage(ac_damage_NdM(N, M, m), m:res_fire()), m)
        totDmg = totDmg + dmg
      elseif not you.see_cell(x+x2, y+y2) then
        totDmg = totDmg + 0.1 -- just slightly prefer to hit out of sight tiles, in case they have enemies
      elseif avoidPlayer and x+x2 == 0 and y+y2 == 0 then
        return 0 -- don't hit yourself
      elseif friendly_at(x+x2, y+y2) then
        return 0
      end
    end
  end
  return totDmg
end

function castable(spellname)
  if not spells.memorised(spellname) then
    return false
  end
  if spells.fail(spellname) > 14 then
    return false
  end
  if spellname == "flame wave" and you.mp() < flamewave_mp() then
    return false
  elseif you.mp() < spells.level(spellname) then
    return false
  end
  if spells.fail_severity(spellname) > 2 then
    return false
  end
  return true
end

function beam_damage_electric(spellname, x, y, N, M)
  local path = spells.path(spellname,x,y)
  local totDmg = 0
  for cell = 1,#path do
    local x2, y2
    x2 = path[cell][1]
    y2 = path[cell][2]
    local m = monster_array[x2][y2]
    if valid_enemy(x2, y2) and totDmg ~= -1 then
      local dmg = mondam_cache[spellname .. "|" .. x2 .. "," .. y2] or damage_value(spellname, resisted_damage(ac_damage_NdM_ac(N, M, guess_ac(m)/2), m:res_shock()), m) * evasion_check(m, spellname)
      totDmg = totDmg + dmg
    elseif friendly_at(x2, y2) and m:res_shock() < 2 then -- friend monster in the way who could be hurt
      totDmg = -1
    end
  end
  return totDmg
end

function magnavolt_damage(targets)
  -- player_damage = 4, 9, 1, 10
  -- monster_damage = nil
  -- dice_def(numdice, adder + pow * mult_num/mult_denom)
  -- 4d(9+power/10)
  local N = 4
  local M = 9 + spellpower("magnavolt")/10
  local dmg = 0
  local i
  for i = 1,#targets do
    dmg = dmg + beam_damage_electric("magnavolt", targets[i][1], targets[i][2], N, M)
  end
  return dmg
end

function evaluate_magnavolt()
  local x, y
  local targets = {}
  local bestTarget = {0, 0}
  local bestDmg = 0
  local range = spells.max_range("magnavolt")
  for x = -range,range do
    for y = -range,range do
      local m = monster_array[x][y]
      local dusted = view.cloud_at(x, y) == "magnetised fragments"
      if m and m:status("covered in magnetic dust") and valid_enemy(x, y) then
        bestTarget = {x, y} -- pick any enemy as a default target
        dusted = true
      end
      if dusted then
        targets[#targets + 1] = {x, y}
      elseif view.cloud_at(x, y) == "magnetised fragments" then
        targets[#targets + 1] = {x, y}
      end
    end
  end
  if #targets > 0 then
    local dmg = magnavolt_damage(targets)
    if dmg > bestDmg then
      bestDmg = dmg
    end
  end
  bpr("magnavolt damage" .. bestDmg)
  for x = -range,range do
    for y = -range,range do
      if valid_enemy(x,y) then
        local m = monster_array[x][y]
        local dusted = (m and m:status("covered in magnetic dust")) or view.cloud_at(x, y) == "magnetised fragments"
        if not dusted then
          targets[#targets + 1] = {x, y}
          local dmg = magnavolt_damage(targets)
          if dmg > bestDmg then
            bestDmg = dmg
            bestTarget = {x, y}
          end
          table.remove(targets, #targets)
        end
      end
    end
  end
  return {bestDmg, "magnavolt", bestTarget[1], bestTarget[2]}
end

function evaluate_fireball()
  local bestX = 0
  local bestY = 0
  local bestDmg = 0
  local range = spells.max_range("fireball")
  local x, y
  local N = 3
  local M = 3.33 + spellpower("fireball")/6
  for x = -range,range do
    for y = -range,range do
      if can_target(x, y) then
        local path = spells.path("fireball",x,y)
        if not blocked_beam(path) then
          local x2 = path[#path][1]
          local y2 = path[#path][2]
          local dmg = fireball_damage_at_target(x2, y2, N, M, true)
          if dmg > bestDmg then
            bestDmg = dmg
            bestX = x
            bestY = y
          end
        end
      end
    end
  end
  return {bestDmg, "fireball", bestX, bestY}
end

function evasion_check(m, spellname)
  local s = m:target_spell(spellname)
  local i, j = string.find(s, "%% to hit")
  if i ~= nil then
    local pct = string.sub(s, i-3, i-1)
    if tonumber(pct) == nil then
      pct = string.sub(s, i-2, i-1)
    end
    if tonumber(pct) == nil then
      pct = string.sub(s, i-1, i-1)
    end
    return tonumber(pct) * 0.01
  end
  return 1.0
end

function evaluate_starburst()
  local totDmg = 0
  -- 6d(3+Power/9)
  local N = 6
  local M = 3 + spellpower("starburst")/9
  local range = spells.max_range("starburst")
  local ranges = {}
  local x, y
  for x=-1,1 do
    ranges[x] = {}
    for y=-1,1 do
      ranges[x][y] = range
    end
  end
  for R = 1,LOS do
    for x=-1,1 do
      for y=-1,1 do
        if x ~= 0 or y ~= 0 then
          local m = monster_array[R*x][R*y]
          if m ~= nil and valid_enemy(R*x, R*y) and ranges[x][y] >= R then
            local dmg = ac_damage_NdM(N, M, m)
            dmg = damage_value(nil, resisted_damage(dmg, m:res_fire()), m)
            dmg = dmg * evasion_check(m, "starburst")
            totDmg = totDmg + dmg
            ranges[x][y] = ranges[x][y] - 1
          end
        end
      end
    end
  end
  return {totDmg, "starburst", 0, 0}
end

function is_on_stairs()
  if string.find(view.feature_at(0,0), "stairs") then
    return true
  end
  return false
end

function is_wall(x, y)
  return travel.feature_solid(view.feature_at(x, y))
end

function ood_obstacle(x, y, x2, y2)
  if is_wall(x2, y2) or firewood_at(x2, y2) then
    return true
  end
  m = monster_array[x2][y2]
  if ((x2 ~= x or y2 ~= y) and m and m:name() ~= "battlesphere" and m:name() ~= "orb of destruction") then
    return true
  end
  return false
end

-- TODO track whether the target already has an OOD en route that is likely to kill them, and don't shoot a second
function ood_damage_at_target(x, y, m)

  -- if dist < 4
  -- 9d((60*dist*3/10 + pow*dist*3/10)/12)
  -- 9d((5 + pow/12) * dist * 3/10)
  --
  -- if dist >= 4, 9d(5 + pow/12)
  -- 9d(5 + Power/12)
  local dist = math.max(math.abs(x), math.abs(y))
  if dist > 3 then
    dist = dist - 1 -- assume enemy will take a step forward before being hit
  end
  local N = 9
  local M = 5 + spellpower("orb of destruction") / 12
  if dist < 4 then
    M = M * dist * 0.3
  end
  local baseDamage = damage_value(nil, ac_damage_NdM(N, M, m), m)
  baseDamage = sh_damage(baseDamage, m)

  local x2, y2
  local xstart, ystart
  local xend, yend
  xstart = 1
  ystart = 1
  xend = x
  yend = y
  if math.abs(x) < math.abs(y) then
    xstart = 0
  end
  if math.abs(y) < math.abs(x) then
    ystart = 0
  end
  if x < 0 then
    xend = -xstart
    xstart = x
  end
  if y < 0 then
    yend = -ystart
    ystart = y
  end
  for x2=xstart,xend do
    for y2=ystart,yend do
      if ood_obstacle(x, y, x2, y2) then
        return 0
      end
    end
  end
  return baseDamage
end

function evaluate_ood()
  -- first check if there's an ood adjacent, and don't shoot if so
  local x1, y1
  for x1=-1,1 do
    for y1=-1,1 do
      local m = monster_array[x1][y1]
      if m and m:name() == "orb of destruction" then
        return {0, "orb of destruction", 0, 0}
      end
    end
  end
  local bestDmg=0
  local bestX=0
  local bestY=0
  local x, y
  for x=-LOS,LOS do
    for y=-LOS,LOS do
      local m = monster_array[x][y]
      if m and m:attitude() == 0 and you.see_cell_solid_see(x, y) then
        local dmg = ood_damage_at_target(x, y, m)
        if dmg > bestDmg then
          bestX = x
          bestY = y
          bestDmg = dmg
        end
      end
    end
  end
  return {bestDmg, "orb of destruction", bestX, bestY}
end

function evaluate_ignition()
  local totDmg=0
  -- 3d(3.33+Power/9)
  local N = 3
  local M = 3.33 + spellpower("ignition") / 9
  
  local x, y
  for x=-LOS,LOS do
    for y=-LOS,LOS do
      local m = monster_array[x][y]
      if valid_enemy(x, y) then
        local dmg = fireball_damage_at_target(x, y, N, M, false)
        totDmg = totDmg + dmg
      end
    end
  end
  return {totDmg, "ignition", 0, 0}
end

function flame_cloud_damage(m)
  -- (2d16)/2 + 5
  -- var_NdM = N * (M^2 - 1) / 12.0
  -- mean_NdM = N * (M + 1) / 2.0
  local mu = (2 * (16 + 1) / 2) / 2 + 5
  local s2 = (2 * (16*16 - 1) / 12) / 4
  return resisted_damage(ac_damage_mus2(mu, s2, guess_ac(m)), m:res_fire())
end

function firestorm_damage_at_target(x, y, N, M)
  local totDmg = 0
  local x2, y2
  local pow = spellpower("fire storm")
  for x2 = -3, 3 do
    for y2 = -3, 3 do
      local m = monster_array[x+x2][y+y2]
      if valid_enemy_explosion(m, x+x2, y+y2, x, y) and view.cell_see_cell(x, y, x+x2, y+y2) then
        local dmg = mondam_cache["firestorm|" .. (x+x2) .. "," .. (y+y2)]
        if dmg == nil then
          dmg = ac_damage_NdM(N, M, m)
          dmg = resisted_damage(dmg*0.55, m:res_fire()) + dmg * 0.45
          local cloudDmg = flame_cloud_damage(m) * 2 -- assume it stays in the cloud for 2 turns
          dmg = damage_value("firestorm", dmg + cloudDmg, m)
        end
        if math.abs(x2) == 3 or math.abs(y2) == 3 then
          dmg = dmg * pow / 1000.0 -- chance of larger firestorm radius
        end
        totDmg = totDmg + dmg
      elseif math.abs(y2) <= 2 and math.abs(x2) <= 2 and not you.see_cell(x+x2, y+y2) and (view.cell_see_cell(x, y, x+x2, y+y2) or math.abs(x+x2) > LOS or math.abs(y+y2) > LOS) then
        totDmg = totDmg + 0.1 -- just slightly prefer to hit cells out of sight
      elseif math.abs(y2) <= 2 and math.abs(x2) <= 2 and is_wall(x+x2, y+y2) then
        totDmg = totDmg - 0.01 -- all other things equal, prefer to hit an open space
      end
    end
  end
  return totDmg
end


function evaluate_firestorm()
  local bestX = 0
  local bestY = 0
  local bestDmg = 0
  -- 8d(0.625+Power/8)
  local N = 8
  local M = 0.625 + spellpower("fire storm")/8
  -- also creates clouds
  local range = spells.max_range("fire storm")
  local x, y
  for x = -range,range do
    for y = -range,range do
      if (math.abs(x) > 3 or math.abs(y) > 3) and can_smite(x, y) then
        local dmg = firestorm_damage_at_target(x, y, N, M)
        if dmg > bestDmg then
          bestDmg = dmg
          bestX = x
          bestY = y
        end
      end
    end
  end
  return {bestDmg, "fire storm", bestX, bestY}
end

function evaluate_arcjolt()
  local hit_array = {}
  local x
  local y
  local M = 10 + spellpower("arcjolt")/2.0
  for x = -LOS-5,LOS+5 do
    hit_array[x] = {}
    for y = -LOS-5,LOS+5 do
      hit_array[x][y] = 0
    end
  end
  hit_array[0][0] = 1

  local r
  local x2, y2
  local totDam = 0
  for r = 1,LOS do
    local hitAnother = false
    for x = -r,r do
      for y = -r,r do
        local m = monster_array[x][y]
        if hit_array[x][y] == 0 and m ~= nil then
          local hitHere = false
          for x2=-1,1 do
            for y2=-1,1 do
              if hit_array[x+x2][y+y2] == 1 then
                hitAnother = true
                hitHere = true
                hit_array[x][y] = 1
                if m:attitude() == 0 and not m:is_firewood() then
                  totDam = totDam + damage_value(nil, resisted_damage(ac_damage_NdM_ac(1, M, guess_ac(m)/2), m:res_shock()), m)
                end
                break
              end
            end
            if hitHere then break end
          end
        end
      end
    end
    if hitAnother ~= true then break end
  end
  
  return {totDam, "arcjolt", 0, 0}
end

function evaluate_foxfire()
  -- 2 * 1d(4+ Power/5)
  local N = 2
  local M = 4 + spellpower("foxfire")/5.0
  local dmg = 0
  local bestDmg = 0
  local closest = LOS+1
  for x=-LOS,LOS do
    for y=-LOS,LOS do
      if valid_enemy(x, y) then
        local m = monster_array[x][y]
        local r = math.max(math.abs(x), math.abs(y))
        dmg = damage_value(nil, resisted_damage(N*ac_damage_NdM(1, M, m), m:res_fire()), m)
        if r < closest or (r == closest and dmg > bestDmg) then
          bestDmg = dmg
          closest = r
        end
      end
    end
  end
  local freeCount = 0
  for x=-1,1 do
    for y=-1,1 do
      if (x ~= 0 or y ~= 0) and not is_wall(x, y) and not monster_array[x][y] then
        freeCount = freeCount + 1
      end
    end
  end
  if freeCount == 0 then
    return {0, "foxfire", 0, 0}
  end
  if freeCount == 1 then
    return {bestDmg / 4.0, "foxfire", 0, 0}
  end
  if freeCount == 2 then
    return {bestDmg / 2.0, "foxfire", 0, 0}
  end
  return {bestDmg, "foxfire", 0, 0}
end

-- Wave status:  Wave, Wave+, Wave++, Wave+++
-- this is not available to lua directly but we can scrape the message buffer
-- When we cast flamewave, and each turn we maintain it, it says:
-- "A wave of flame ripples out!"
-- The first time we cast it, it says:
-- "(Press . to intensify the flame waves.)"
-- it ends if we are trampled, blinked, dispersal trap'd, or teleported
-- "You blink"
-- also it ends if we cast a spell, take a step, hit with a melee weapon, change jewellery, etc
function flamewave_turns()
  if flamewave_last_turn ~= you.turns() - 1 then
    return 0
  end
  local messages = crawl.messages(100)
  -- delete messages up to the last cast of flame wave
  messages = string.gsub(messages, ".*A wave of flame ripples out!", "")
  if string.find(messages, "You blink") then
    return 0
  end
  if string.find(messages, "Your surroundings") then -- teleported
    return 0
  end
  if string.find(messages, "stumble backwards") then
    return 0
  end
  if string.find(messages, "drags you backwards") then
    return 0
  end
  if string.find(messages, "You miscast Flame Wave") then
    return 0
  end
  
  if you.turns() - flamewave_start_turn < spells.max_range("flame wave") then
    return you.turns() - flamewave_start_turn
  end
  return 0
end

function flamewave_mp()
  local flame_range = flamewave_turns() + 1
  if flame_range == 1 then
    return spells.level("flame wave")
  end
  return 1
end

-- local messages = crawl.messages(100)
function evaluate_flamewave()
  local flame_range = flamewave_turns() + 1
  -- 2d(4.5+Power/6)
  local N = 2
  local M = 4.5 + spellpower("flame wave")/6
  local totDmg = 0
  for x=-flame_range,flame_range do
    for y=-flame_range,flame_range do
      if valid_enemy(x, y) then
        local m = monster_array[x][y]
        local dmg = damage_value(nil, resisted_damage(ac_damage_NdM(N, M, m), m:res_fire()), m)
        totDmg = totDmg + dmg
      end
    end
  end
  return {totDmg, "flame wave", 0, 0}
end

function evaluate_arrow(spellname, N, M)
  local range = spells.max_range(spellname)
  local x, y
  local bestDmg = 0
  local bestX = 0
  local bestY = 0
  for x = -range,range do
    for y = -range,range do
      if can_target(x, y) then
        local path = spells.path(spellname,x,y)
        if not blocked_beam(path) then
          local cell
          local totDmg = 0
          local reachChance = 1.0
          for cell = 1,#path do
            local x2, y2
            x2 = path[cell][1]
            y2 = path[cell][2]
            local m = monster_array[x2][y2]
            if valid_enemy(x2, y2) and totDmg ~= -1 then
              local hitChance = evasion_check(m, spellname)
              local dmg = mondam_cache[spellname .. "|" .. x2 .. "," .. y2] or damage_value(spellname, ac_damage_NdM(N, M, m), m)
              dmg = sh_damage(dmg * reachChance * hitChance, m)
              reachChance = reachChance * (1 - hitChance)
              totDmg = totDmg + dmg
            elseif m and m:name() ~= "battlesphere" then -- non-enemy monster in the way
              totDmg = -1
            end
          end
          if totDmg > bestDmg then
            bestDmg = totDmg
            bestX = x
            bestY = y
          end
        end
      end
    end
  end
  return {bestDmg, spellname, bestX, bestY}

end

function evaluate_stonearrow()
  -- 3d(7+power/8)
  local N = 3
  local M = 7 + spellpower("stone arrow")/8
  
  return evaluate_arrow("stone arrow", N, M)
end

function evaluate_lcs()
  -- 10d(2.3 + power/10)
  local N = 10
  local M = 2.3 + spellpower("lehudib's crystal spear")/10
  return evaluate_arrow("lehudib's crystal spear", N, M)
end

function evaluate_bombard()
  -- 9d(1.44+Power/13)
  if is_on_stairs() then
    -- don't bombard ourselves off the stairs!
    return {0, "bombard", 0, 0}
  end
  local N = 9
  local M = 1.44 + spellpower("bombard")/13
  return evaluate_arrow("bombard", N, M)
end

-- returns number of dice and explosion radius, and whether it's ice. see spl-damage.cc
function lrd_dice_terrain(feature)
  feature = string.lower(feature)
  if string.find(feature, "stair") then
    return {0, 0, false}
  end
  local featuresRock = {"stone", "rock", "door", "slimy_wall", "petrified", "statue"}
  local featuresMetal = {"metal", "iron"}
  local featuresCrystal = {"crystal"}
  local i
  for i = 1,#featuresRock do
    if string.find(feature, featuresRock[i]) then
      return {3, 1, false}
    end
  end
  for i = 1,#featuresMetal do
    if string.find(feature, featuresMetal[i]) then
      return {4, 1, false}
    end
  end
  for i = 1,#featuresCrystal do
    if string.find(feature, featuresCrystal[i]) then
      return {4, 2, false}
    end
  end
  return {0, 0, false}
end

-- number of dice, radius, and whether it's ice. see mon-data.cc and spl-damage.cc
function lrd_dice_monster(monster)
  monster = string.lower(monster)
  local monstersMetal = {"iron golem", "iron elemental", "peacekeeper", "war gargoyle"}
  local monstersIce = {"ice beast", "simula", "ice statue"}
  local monstersRockBone = {"toenail", "earth elemental", "saltling", "ushabti", "statue", "gargoyle", "skelet", "bone", "ancient champion", "revenant", "skull", "Murray", "rockslime"}
  local monstersCrystal = {"orange statue", "crystal guardian", "orange crystal statue", "crystal echidna", "obsidian", "roxanne", "glass eye"}
  -- check metal first because of war gargoyle/gargoyle
  for i = 1,#monstersMetal do
    if string.find(monster, monstersMetal[i]) then
      return {4, 1, false}
    end
  end
  for i = 1,#monstersCrystal do
    if string.find(monster, monstersCrystal[i]) then
      return {4, 2, false}
    end
  end
  for i = 1,#monstersRockBone do
    if string.find(monster, monstersRockBone[i]) and monster ~= "molten gargoyle" then
      return {3, 1, false}
    end
  end
  for i = 1,#monstersIce do
    if string.find(monster, monstersIce[i]) then
      return {3, 1, true}
    end
  end
  return {0, 0, false}
end

function lrd_damage_at_target(x, y, dmgPerDice, dice, radius, fromMonster, fromIce)
  local x2, y2
  local totDmg = 0
  for x2 = -radius,radius do
    for y2 = -radius,radius do
      if view.cell_see_cell (x, y, x+x2, y+y2) then
        local m = monster_array[x+x2][y+y2]
        if valid_enemy(x+x2, y+y2) then
          if x2 == 0 and y2 == 0 and fromMonster then
            totDmg = totDmg + damage_value(nil, dmgPerDice * dice, m)
          elseif not fromIce then
            totDmg = totDmg + damage_value(nil, ac_damage_NdM_ac(dice, dmgPerDice, guess_ac(m)*3), m)
          else
            totDmg = totDmg + damage_value(nil, resisted_damage(ac_damage_NdM_ac(dice, dmgPerDice, guess_ac(m)), m:res_cold()), m)
          end
        elseif friendly_at(x+x2, y+y2) then
          return 0 -- don't hit neutrals, even unfriendly ones.
        elseif x+x2 == 0 and y+y2 == 0 then
          return 0 -- don't hit the player
        end
      end
    end
  end
  return totDmg
end

function evaluate_lrd()
  local dmgPerDice = math.floor(5 + spellpower("lee's rapid deconstruction")/5.0)
  
  local bestX = 0
  local bestY = 0
  local bestDmg = 0
  local range = spells.max_range("lee's rapid deconstruction")
  local x, y
  for x = -range,range do
    for y = -range,range do
      if you.see_cell_solid_see(x, y) then
        local feature = view.feature_at(x, y)
        local lrdDice = {0, 0}
        local m = monster_array[x][y]
        local fromMonster = false
        if m then
           lrdDice = lrd_dice_monster(m:name())
        end
        if lrdDice[1] == 0 then
           lrdDice = lrd_dice_terrain(feature)
        else
           fromMonster = true
        end
        if lrdDice[1] ~= 0 then
          local dmg = lrd_damage_at_target(x, y, dmgPerDice, lrdDice[1], lrdDice[2], fromMonster, lrdDice[3])
          if dmg > bestDmg then
            bestDmg = dmg
            bestX = x
            bestY = y
          end
        end
      end
    end
  end
  return {bestDmg, "lee's rapid deconstruction", bestX, bestY}
end

-- for some reason lrd can't be cast with spells.cast
-- so this is a workaround
function cast_lrd(x, y)
  local cmdStr = "Z" .. spells.letter("lee's rapid deconstruction") .. "r"
  local x2, y2
  if x < 0 then
    for x2 = x,-1 do
      cmdStr = cmdStr .. "h"
    end
  elseif x > 0 then
    for x2 = 1,x do
      cmdStr = cmdStr .. "l"
    end
  end
  if y < 0 then
    for y2 = y,-1 do
      cmdStr = cmdStr .. "k"
    end
  elseif y > 0 then
    for y2 = 1,y do
      cmdStr = cmdStr .. "j"
    end
  end
  cmdStr = cmdStr .. "."
  crawl.process_keys(cmdStr)
end

function evaluate_scorch()
   -- 2d(5+Power/10)
  local N = 2
  local M = 5 + spellpower("scorch")/10
  local range = spells.range("scorch")
  local x, y
  local totDmg = 0
  local numEnemies = 0
  for x=-range,range do
    for y=-range,range do
      local m = monster_array[x][y]
      if valid_enemy(x, y) then
        totDmg = totDmg + damage_value(nil, resisted_damage(ac_damage_NdM(N, M, m), m:res_fire()), m)
        numEnemies = numEnemies + 1
      end
    end
  end
  if numEnemies == 0 then
    return {0, "scorch", 0, 0}
  end
  -- too many enemies in range isn't good because it hits randomly
  if numEnemies > 2 then
    return {0.5 * totDmg / numEnemies, "scorch", 0, 0}
  end
  return {totDmg / numEnemies, "scorch", 0, 0}
end

function count_empty_spaces(x, y)
  local x2, y2
  local emptyCount = 0
  for x2=-1,1 do
    for y2=-1,1 do
      if not is_wall(x+x2, y+y2) and not monster_array[x+x2][y+y2] then
        emptyCount = emptyCount + 1
      end
    end
  end
  return emptyCount
end

function evaluate_airstrike()
  -- 2d([power + 13]/14 + 2m) where m = empty spaces
  local N = 2
  local M = (spellpower("airstrike") + 13)/14 -- + 2m
  local bestX=0
  local bestY=0
  local bestDmg = 0
  local x, y
  for x=-LOS,LOS do
    for y=-LOS,LOS do
      local m = monster_array[x][y]
      if valid_enemy(x, y) and can_smite(x, y) then
        local dmg = damage_value(nil, ac_damage_NdM(N, M + 2 * count_empty_spaces(x, y), m), m)
        if dmg > bestDmg then
          bestDmg = dmg
          bestX = x
          bestY = y
        end
      end
    end
  end
  return {bestDmg, "airstrike", bestX, bestY}
end

function evaluate_shock()
  -- 1d(3+power/4) -- 1 3 1 4
  local N = 1
  local M = 3 + spellpower("shock")/4
  local range = spells.max_range("shock")
  local x, y
  local bestDmg = 0
  local bestX = 0
  local bestY = 0
  for x = -range,range do
    for y = -range,range do
      if can_target(x, y) then
        local cell
        local totDmg = beam_damage_electric("shock", x, y, N, M)
        if totDmg > bestDmg then
          bestDmg = totDmg
          bestX = x
          bestY = y
        end
      end
    end
  end
  return {bestDmg, "shock", bestX, bestY}
end

function plasmabeam_helper(x, y, tally)
  if not valid_enemy(x, y) then
    return
  end
  -- 2 x 1d(11+(3*Power)/5)
  local N = 1
  local M = 11 + (3*spellpower("plasma beam"))/5
  tally[0] = tally[0] + 1
  local path = spells.path("plasma beam", x, y)
  for cell=1,#path do
    local x2, y2
    x2 = path[cell][1]
    y2 = path[cell][2]
    local m = monster_array[x2][y2]
    if valid_enemy(x2, y2) then
      local dmg = mondam_cache["plasma beam elec|" .. x2 .. "," .. y2] or damage_value("plasma beam elec", resisted_damage(ac_damage_NdM_ac(N, M, guess_ac(m)/2), m:res_shock()), m) * evasion_check(m, "plasma beam")
      local dmg2 = mondam_cache["plasma beam fire|" .. x2 .. "," .. y2] or damage_value("plasma beam fire", resisted_damage(ac_damage_NdM_ac(N, M, guess_ac(m)/2), m:res_fire()), m) * evasion_check(m, "plasma beam")
      tally[1] = tally[1] + dmg + dmg2
    elseif friendly_at(x2, y2) and m:name() ~= "battlesphere" then -- friend monster in the way who could be hurt
      tally[1] = -1000 -- don't shoot if we might hit friendlies
    end
  end
end

function evaluate_plasmabeam()
  local range = spells.max_range("plasma beam")
  local x, y
  local bestDmg = 0
  local bestX = 0
  local bestY = 0
  local maxRange = 0
  local tally = {0, 0} -- {target count, total damage}
  tally[0] = 0
  for x = -range,range do
    for y = -range,range do
      if valid_enemy(x, y) then
        if math.abs(x) > maxRange then
          maxRange = math.abs(x)
        end
        if math.abs(y) > maxRange then
          maxRange = math.abs(y)
        end
      end
    end
  end
  range = maxRange

  local z = -range
  for z = -range,range do
    plasmabeam_helper(z, -range, tally)
    if z > -range then
      plasmabeam_helper(-range, z, tally)
      plasmabeam_helper(z, range, tally)
      if z < range then
        plasmabeam_helper(range, z, tally)
      end
    end
  end

  if tally[0] == 0 then
    tally[0] = 1
  end
  return {tally[1]/tally[0], "plasma beam", 0, 0}
end

function evaluate_irradiate()
  if you.contaminated() > 1 then -- another cast of this might give yellow contam
    return {0, "irradiate", 0, 0}
  end
  -- 3d(11.66 + power/6)
  local N = 3
  -- +10 because the malmutate status is worth something
  local M = 11.66 + spellpower("irradiate")/6 + 10
  local totDmg = 0
  local totEnemyThreat = 0
  for x=-1,1 do
    for y=-1,1 do
      if valid_enemy(x, y) then
        local m = monster_array[x][y]
        totDmg = totDmg + damage_value(nil, ac_damage_NdM(N, M, m), m)
        totEnemyThreat = totEnemyThreat + m:threat()
      end
    end
  end
  if totEnemyThreat < 3 and you.mp() > 10 then
    -- don't cast irradiate without a good reason, i.e. multiple dangerous adjacent enemies or low on mp
    return {0, "irradiate", 0, 0}
  end
  return {totDmg, "irradiate", 0, 0}
end

function evaluate_imb()
  -- 3d(11.66 + power/6)
  local N = 2
  local M = 3 + spellpower("iskenderun's mystic blast")/6
  local range = spells.range("iskenderun's mystic blast")
  local totDmg = 0
  local totEnemyThreat = 0
  for x=-range,range do
    for y=-range,range do
      local m = monster_array[x][y]
      if valid_enemy(x, y) then
        totDmg = totDmg + damage_value(nil, ac_damage_NdM(N, M, m), m)
      elseif friendly_at(x, y) and m:name() ~= "battlesphere" then -- friend monster in the way who could be hurt
        totDmg = -1000 -- don't shoot if we might hit friendlies
      end
    end
  end
  return {totDmg, "iskenderun's mystic blast", 0, 0}
  
end

-- function evaluate_poisonousvapours()
--   if not castable("poisonous vapours") then
--     return {0, "poisonous vapours", 0, 0}
--   end
--   -- there isn't a specific damage formula for poisonous vapours
--   -- we'll begin by assuming it is similar in value to scorch
--   -- (below is the damage formula for scorch)
--   local dmgPerHit = 2 * 0.5 * math.floor(6 + spellpower("poisonous vapours")/10.0)
--   -- targeting: we only want to target non-poison-resistant creatures
--   -- that are not already maximally poisoned
--   -- giving priority to the monster that is currently the most poisoned
--   -- and breaking ties going to the most dangerous monster
--   -- status() can be "poisoned", "very poisoned", "extremely poisoned"
--   local bestDmg = 0
--   local bestX, bestY
--   local x, y
--   local range = spells.max_range("poisonous vapours")
--   for x=-range,range do
--     for y=-range,range do
--       local m = monster_array[x][y]
--       if m and m:res_poison() <= 0 and not m:status("extremely poisoned") then
--         local dmg = damage_value(nil, dmgPerHit, m)
--         if m:threat() < 2 then
--           dmg = dmg * 0.5
--         elseif m:threat() > 3 then
--           dmg = dmg * 1.5
--         end
--         if m:status("very poisoned") then
--           dmg = dmg * 1.1
--         elseif m:status("poisoned") then
--           dmg = dmg * 1.05
--         end
--         if dmg > bestDmg then
--           bestDmg = dmg
--           bestX = x
--           bestY = y
--         end
--       end
--     end
--   end
--   return {bestDmg, "poisonous vapours", bestX, bestY}
-- end

function bpr(message)
  crawl.mpr(tostring(message))
end

spelltable = {["orb of destruction"]= evaluate_ood, starburst =  evaluate_starburst, foxfire =  evaluate_foxfire, ["stone arrow"]=  evaluate_stonearrow, bombard =  evaluate_bombard, scorch =  evaluate_scorch, airstrike =  evaluate_airstrike, shock = evaluate_shock, ["flame wave"] =  evaluate_flamewave, irradiate = evaluate_irradiate, ["lehudib's crystal spear"] =  evaluate_lcs, ["iskenderun's mystic blast"] =  evaluate_imb, fireball =  evaluate_fireball, ignition = evaluate_ignition, ["fire storm"] = evaluate_firestorm, ["lee's rapid deconstruction"] =  evaluate_lrd, ["arcjolt"] = evaluate_arcjolt, ["plasma beam"] = evaluate_plasmabeam, magnavolt = evaluate_magnavolt}

monster_ac = {["adder"] =  1 ,["jelly"] =  0 ,["Tiamat"] =  30 ,["Sonja"] =  2 ,["jumping spider"] =  6 ,["spatial vortex"] =  0 ,["formicid"] =  3 ,["queen bee"] =  10 ,["acid dragon"] =  5 ,["rime drake"] =  3 ,["dwarf"] =  2 ,["centaur"] =  3 ,["orb of destruction"] =  0 ,["deep elf zephyrmancer"] =  0 ,["hobgoblin"] =  2 ,["Amaemon"] =  3 ,["deep troll shaman"] =  6 ,["shadow imp"] =  3 ,["human"] =  3 ,["eldritch tentacle segment"] =  13 ,["twister"] =  0 ,["bat"] =  1 ,["glowing shapeshifter"] =  0 ,["Bai Suzhen"] =  22 ,["golden dragon"] =  15 ,["draconian annihilator"] =  -1 ,["ophan"] =  10 ,["white draconian"] =  9 ,["death knight"] =  2 ,["radroach"] =  13 ,["Rupert"] =  0 ,["sky beast"] =  3 ,["test spawner"] =  127 ,["ballistomycete spore"] =  0 ,["black mamba"] =  4 ,
["the Serpent of Hell"] =  16 ,["Gloorx Vloq"] =  10 ,["Roxanne"] =  20 ,["withered plant"] =  0 ,["white imp"] =  4 ,["Grinder"] =  3 ,["thermic dynamo"] =  4 ,["deep elf sorcerer"] =  0 ,["spectral thing"] =  8 ,["deep elf blademaster"] =  0 ,["bunyip"] =  6 ,["flayed ghost"] =  0 ,["kraken"] =  20 ,["bone dragon"] =  20 ,["bombardier beetle"] =  4 ,["tentacle segment"] =  5 ,["shard shrike"] =  2 ,["yaktaur"] =  4 ,["alligator"] =  4 ,["the Royal Jelly"] =  8 ,["emperor scorpion"] =  18 ,["snake"] =  0 ,["curse skull"] =  35 ,["tentacle"] =  5 ,["Gastronok"] =  2 ,["small abomination"] =  0 ,["minotaur"] =  6 ,["acid blob"] =  1 ,["deep elf master archer"] =  0 ,["orange demon"] =  3 ,["Executioner"] =  10 ,["naga"] =  6 ,["frilled lizard"] =  0 ,["oni"] =  1 ,["Louise"] =  0 ,["Murray"] =  30 ,["water elemental"] =  4 ,["bound soul"] =  8 ,["culicivora"] =  2 ,["mummy priest"] =  8 ,["green draconian"] =  9 ,["tentacled starspawn"] =  5 ,["faun"] =  2 ,["fire crab"] =  9 ,["yaktaur captain"] =  5 ,["pandemonium lord"] =  1 ,
["servant of whispers"] =  1 ,["komodo dragon"] =  7 ,["occultist"] =  0 ,["goliath frog"] =  3 ,["hydra"] =  0 ,["hellwing"] =  16 ,["Mara"] =  10 ,["orc"] =  0 ,["dream sheep"] =  2 ,["wolf"] =  4 ,["gargoyle"] =  18 ,["Urug"] =  2 ,["Norris"] =  1 ,["ribbon worm"] =  1 ,["Sojobo"] =  2 ,["boggart"] =  0 ,["skyshark"] =  6 ,["Maggie"] =  0 ,["trivial sensed monster"] =  0 ,["reaper"] =  15 ,["Lom Lobon"] =  10 ,["large simulacrum"] =  10 ,["small zombie"] =  0 ,["satyr"] =  2 ,["fire vortex"] =  0 ,["ancient champion"] =  15 ,["mutant beast"] =  8 ,["demigod"] =  2 ,["snapping turtle"] =  16 ,["hell hound"] =  6 ,["spark wasp"] =  9 ,["deep troll earth mage"] =  12 ,["draconian"] =  10 ,["deep elf death mage"] =  0 ,["manticore"] =  5 ,["sun demon"] =  10 ,["giant cockroach"] =  3 ,["starspawn tentacle"] =  8 ,["spriggan air mage"] =  1 ,["ice dragon"] =  10 ,["halazid warlock"] =  8 ,["laughing skull"] =  4 ,["will-o-the-wisp"] =  4 ,["very ugly thing"] =  6 ,["Duvessa"] =  2 ,["Ijyb"] =  2 ,["hell lord"] =  0 ,["quicksilver dragon"] =  10 ,["entropy weaver"] =  7 ,["Natasha"] =  2 ,["deep elf high priest"] =  3 ,["ghost moth"] =  8 ,["balrug"] =  5 ,["hellion"] =  5 ,["fire elemental"] =  4 ,["dire elephant"] =  13 ,["silent spectre"] =  5 ,["chaos spawn"] =  4 ,["hell rat"] =  7 ,["walking divine tome"] =  10 ,["fungus"] =  0 ,["Sigmund"] =  0 ,["training dummy"] =  0 ,["demonspawn warmonger"] =  3 ,["foxfire"] =  0 ,["molten gargoyle"] =  14 ,["water moccasin"] =  2 ,["starcursed mass"] =  10 ,["Josephine"] =  0 ,["ogre mage"] =  1 ,["merfolk siren"] =  4 ,
["draconian stormcaller"] =  0 ,["easy sensed monster"] =  0 ,["polar bear"] =  7 ,["demonspawn corrupter"] =  3 ,["Psyche"] =  0 ,["harpy"] =  2 ,["inugami"] =  5 ,["angel"] =  10 ,["quasit"] =  5 ,["Parghit"] =  1 ,["moth"] =  0 ,["eleionoma"] =  2 ,["spectral weapon"] =  5 ,["Zenata"] =  10 ,["sixfirhy"] =  2 ,["royal mummy"] =  10 ,["orc knight"] =  2 ,["blazeheart golem"] =  9 ,["merfolk avatar"] =  4 ,["vault guard"] =  1 ,["halfling"] =  2 ,["orb of fire"] =  20 ,["iron elemental"] =  20 ,["ancient lich"] =  20 ,["curse toe"] =  25 ,["demonspawn blood saint"] =  6 ,["tengu conjurer"] =  2 ,["boulder"] =  10 ,["orc sorcerer"] =  5 ,["Vv"] =  27 ,["purple draconian"] =  9 ,["guardian mummy"] =  6 ,["draconian monk"] =  -3 ,["eidolon"] =  12 ,["sphinx"] =  5 ,["ynoxinul"] =  3 ,["fire bat"] =  1 ,["ironbound frostheart"] =  0 ,["death drake"] =  6 ,["shadow"] =  7 ,["stone giant"] =  12 ,["wight"] =  4 ,["bloated husk"] =  5 ,["ironbound preserver"] =  0 ,["wyvern"] =  5 ,["broodmother"] =  2 ,["frost giant"] =  9 ,["water nymph"] =  2 ,["hog"] =  2 ,["Mnoleg"] =  11 ,["Nessos"] =  4 ,["mummy"] =  3 ,["armataur"] =  15 ,["Agnes"] =  0 ,["sea snake"] =  2 ,["iron imp"] =  6 ,["golem"] =  0 ,["smoke demon"] =  5 ,["daeva"] =  10 ,["iron golem"] =  25 ,["Grum"] =  2 ,["Mennas"] =  15 ,["ghoul"] =  4 ,["formless jellyfish"] =  0 ,["animated tree"] =  0 ,["pillar of salt"] =  1 ,["lava snake"] =  2 ,["shadow demon"] =  7 ,["lightning spire"] =  13 ,["nasty sensed monster"] =  0 ,["merfolk javelineer"] =  0 ,["merfolk impaler"] =  0 ,["deep elf demonologist"] =  0 ,["sickly merfolk siren"] =  4 ,["sacred lotus"] =  24 ,["tyrant leech"] =  5 ,["phantasmal warrior"] =  12 ,
["djinni"] =  5 ,["naga mage"] =  6 ,["Polyphemus"] =  10 ,["quokka"] =  2 ,["ball lightning"] =  0 ,["deathcap"] =  5 ,["snaplasher vine segment"] =  6 ,["Terence"] =  0 ,["fire dragon"] =  10 ,["hornet"] =  6 ,["wendigo"] =  4 ,["lich"] =  10 ,["briar patch"] =  10 ,["kobold demonologist"] =  2 ,["naga ritualist"] =  6 ,["fire giant"] =  8 ,["Ignacio"] =  10 ,["bennu"] =  6 ,["Crazy Yiuf"] =  2 ,["ufetubus"] =  2 ,["malarious merfolk avatar"] =  4 ,["giant"] =  0 ,["grey draconian"] =  16 ,["hell hog"] =  2 ,["living spell"] =  0 ,["shambling mangrove"] =  13 ,["sleepcap"] =  5 ,["bullfrog"] =  0 ,["death yak"] =  9 ,["player"] =  0 ,["Dissolution"] =  10 ,["the Lernaean hydra"] =  0 ,["ballistomycete"] =  1 ,["walking frostbound tome"] =  10 ,["elemental wellspring"] =  8 ,["Jory"] =  10 ,["deep elf annihilator"] =  0 ,["iron giant"] =  18 ,["spriggan"] =  1 ,["pale draconian"] =  9 ,["Joseph"] =  0 ,["the Serpent of Hell"] =  20 ,["ancient zyme"] =  6 ,["Chuck"] =  14 ,["nargun"] =  25 ,["ironbound convoker"] =  0 ,["kobold blastminer"] =  4 ,
["peacekeeper"] =  20 ,["dragon"] =  0 ,["deep elf knight"] =  0 ,["small simulacrum"] =  10 ,["shock serpent"] =  2 ,["protean progenitor"] =  7 ,["Margery"] =  0 ,["animated armour"] =  8 ,["Lodul"] =  3 ,["snaplasher vine"] =  4 ,["mana viper"] =  3 ,["goblin"] =  0 ,["imperial myrmidon"] =  1 ,["tengu reaver"] =  2 ,["deep elf elementalist"] =  0 ,["worldbinder"] =  12 ,["orc warrior"] =  0 ,["Frederick"] =  0 ,["Jessica"] =  0 ,["elephant slug"] =  2 ,["moon troll"] =  20 ,["Pikel"] =  4 ,["starspawn tentacle segment"] =  8 ,["Azrael"] =  10 ,["draconian scorcher"] =  -1 ,["Asmodeus"] =  30 ,["seraph"] =  10 ,["soul eater"] =  18 ,["great orb of eyes"] =  10 ,["crystal guardian"] =  20 ,["Khufu"] =  10 ,["salamander"] =  5 ,["golden eye"] =  0 ,["orange crystal statue"] =  12 ,["caustic shrike"] =  8 ,["two-headed ogre"] =  3 ,["rust devil"] =  10 ,["Maurice"] =  1 ,["Nellie"] =  13 ,["naga warrior"] =  6 ,["plant"] =  0 ,["floating eye"] =  0 ,["orc wizard"] =  1 ,["revenant"] =  8 ,["ice beast"] =  5 ,["death cob"] =  10 ,["holy swine"] =  2 ,["fenstrider witch"] =  3 ,["thrashing horror"] =  5 ,["meliai"] =  2 ,["drowned soul"] =  0 ,["demonspawn"] =  3 ,["glowing orange brain"] =  2 ,["war gargoyle"] =  25 ,["pearl dragon"] =  10 ,["spriggan berserker"] =  2 ,["spriggan druid"] =  1 ,["Prince Ribbit"] =  0 ,["vault sentinel"] =  1 ,["Cloud Mage"] =  0 ,["vine stalker"] =  2 ,["Kirke"] =  0 ,["green death"] =  5 ,["centaur warrior"] =  4 ,["basilisk"] =  3 ,["dancing weapon"] =  10 ,["tainted leviathan"] =  15 ,["draconian knight"] =  9 ,["orc warlord"] =  3 ,["raiju"] =  4 ,["diamond obelisk"] =  12 ,["warg"] =  9 ,["electric golem"] =  5 ,["Nergalle"] =  9 ,["fulminant prism"] =  3 ,["scrub nettle"] =  8 ,["martyred shade"] =  0 ,["ugly thing"] =  4 ,["demonspawn black sun"] =  9 ,["Vashnia"] =  6 ,["giant lizard"] =  0 ,["ice devil"] =  12 ,["orc priest"] =  1 ,["Saint Roka"] =  3 ,["storm dragon"] =  13 ,["eldritch tentacle"] =  13 ,["crystal echidna"] =  10 ,["burial acolyte"] =  0 ,["Robin"] =  1 ,["tormentor"] =  12 ,["Jorgrun"] =  2 ,["ironbound thunderhulk"] =  1 ,["glass eye"] =  2 ,["Fannar"] =  4 ,["toenail golem"] =  8 ,["block of ice"] =  15 ,["Hellbinder"] =  0 ,["red devil"] =  7 ,
["ancestor"] =  5 ,["giant frog"] =  0 ,["Killer Klown"] =  10 ,["necromancer"] =  0 ,["meteoran"] =  2 ,["torpor snail"] =  8 ,["electric eel"] =  1 ,["juggernaut"] =  20 ,["hell beast"] =  5 ,["apocalypse crab"] =  11 ,["red draconian"] =  9 ,["tengu warrior"] =  2 ,["rat"] =  1 ,["guardian serpent"] =  6 ,["large zombie"] =  8 ,["Arachne"] =  3 ,["creeping inferno"] =  0 ,["spectator"] =  0 ,["slime creature"] =  1 ,["felid"] =  2 ,["merfolk aquamancer"] =  0 ,["demonic plant"] =  0 ,["doom hound"] =  6 ,["earth elemental"] =  14 ,["merfolk"] =  4 ,["iron dragon"] =  20 ,["Blork the orc"] =  0 ,["elephant"] =  8 ,["cacodemon"] =  11 ,["orc high priest"] =  1 ,["hell knight"] =  0 ,["lemure"] =  4 ,["gnoll sergeant"] =  2 ,["shadow dragon"] =  15 ,["Snorg"] =  0 ,["weeping skull"] =  7 ,["Xtahua"] =  18 ,["phantom"] =  3 ,["Ice Fiend"] =  15 ,["antique champion"] =  20 ,["Aizul"] =  8 ,["spellforged servitor"] =  10 ,["crimson imp"] =  3 ,["Ilsuiw"] =  5 ,["hexer"] =  5 ,["river rat"] =  5 ,["yellow draconian"] =  9 ,["titan"] =  10 ,["wolf spider"] =  3 ,["small skeleton"] =  0 ,["Orb Guardian"] =  13 ,["naga sharpshooter"] =  6 ,["vault warden"] =  1 ,
["the Serpent of Hell"] =  16 ,["ball python"] =  0 ,["the Serpent of Hell"] =  30 ,["steam dragon"] =  5 ,["salamander tyrant"] =  5 ,["swamp worm"] =  3 ,["Frances"] =  0 ,["battlemage"] =  5 ,["death scarab"] =  7 ,["black bear"] =  2 ,["quicksilver ooze"] =  3 ,["arcanist"] =  0 ,["freezing wraith"] =  12 ,["test blob"] =  0 ,["yak"] =  4 ,["Jeremiah"] =  2 ,["deep elf pyromancer"] =  0 ,["jackal"] =  2 ,["spriggan rider"] =  1 ,["insubstantial wisp"] =  0 ,["necrophage"] =  2 ,["tentacled monstrosity"] =  5 ,["efreet"] =  10 ,["saltling"] =  15 ,["nameless horror"] =  8 ,["lost soul"] =  0 ,["octopode"] =  1 ,["Nikola"] =  1 ,["Edmund"] =  0 ,["ragged hierophant"] =  0 ,["strange machine"] =  12 ,["unseen horror"] =  5 ,["spriggan defender"] =  3 ,["shadow"] =  3 ,["dread lich"] =  20 ,["hound"] =  2 ,["nagaraja"] =  6 ,["Bai Suzhen"] =  14 ,["Brimstone Fiend"] =  15 ,["jiangshi"] =  10 ,["large skeleton"] =  0 ,["elemental"] =  0 ,["alligator snapping turtle"] =  19 ,["vampire mage"] =  10 ,["drake"] =  0 ,["catoblepas"] =  10 ,["tarantella"] =  3 ,["lindwurm"] =  8 ,["putrid mouth"] =  5 ,["Josephina"] =  10 ,["skeleton"] =  0 ,["swamp dragon"] =  7 ,
["vampire mosquito"] =  2 ,["Mlioglotl"] =  10 ,["Donald"] =  3 ,["boulder beetle"] =  20 ,["vampire"] =  10 ,["troll"] =  3 ,["bush"] =  15 ,["ice statue"] =  12 ,["kobold"] =  2 ,["gnoll bouda"] =  2 ,["Geryon"] =  15 ,["eye of devastation"] =  12 ,["cerulean imp"] =  3 ,["cyclops"] =  5 ,["toadstool"] =  1 ,["ghost"] =  0 ,["vampire knight"] =  10 ,["simulacrum"] =  10 ,["kobold brigand"] =  3 ,["Menkaure"] =  3 ,["walking earthen tome"] =  20 ,["shapeshifter"] =  0 ,["bear"] =  0 ,["Ereshkigal"] =  10 ,["scorpion"] =  5 ,["blizzard demon"] =  10 ,["rakshasa"] =  6 ,["orb spider"] =  3 ,["spatial maelstrom"] =  0 ,["Pargi"] =  1 ,["Cerebov"] =  30 ,["black draconian"] =  9 ,["Hell Sentinel"] =  25 ,["Harold"] =  0 ,["neqoxec"] =  4 ,["draconian shifter"] =  -1 ,["gnoll"] =  2 ,["statue"] =  12 ,["rockslime"] =  27 ,["wandering mushroom"] =  5 ,["friendly sensed monster"] =  0 ,["Antaeus"] =  28 ,["quicksilver elemental"] =  1 ,["battlesphere"] =  0 ,["Head Instructor"] =  0 ,["Grunn"] =  6 ,["salamander mystic"] =  5 ,["the Enchantress"] =  1 ,["Dispater"] =  35 ,["apis"] =  9 ,["hellephant"] =  13 ,["azure jelly"] =  5 ,["Erolcha"] =  3 ,["Asterion"] =  4 ,["zombie"] =  0 ,["cherub"] =  10 ,["program bug"] =  0 ,["lorocyproca"] =  10 ,["orc apostle"] =  2 ,
["steelbarb worm"] =  11 ,["obsidian statue"] =  12 ,["test statue"] =  0 ,["deep dwarf"] =  2 ,["blazeheart core"] =  0 ,["cactus giant"] =  1 ,["walking crystal tome"] =  15 ,["shadow wraith"] =  7 ,["iguana"] =  5 ,["pharaoh ant"] =  4 ,["brain worm"] =  1 ,["redback"] =  2 ,["Dowan"] =  0 ,["anaconda"] =  4 ,["wraith"] =  10 ,["killer bee"] =  2 ,["merged slime creature"] =  0 ,["butterfly"] =  0 ,["endoplasm"] =  1 ,["moth of wrath"] =  0 ,["wind drake"] =  3 ,["crab"] =  0 ,["aspiring flesh"] =  2 ,["searing wretch"] =  4 ,["jorogumo"] =  4 ,["crocodile"] =  4 ,["starflower"] =  16 ,["barachi"] =  0 ,["ettin"] =  9 ,["ghost crab"] =  9 ,["profane servitor"] =  10 ,["shining eye"] =  3 ,["dryad"] =  6 ,["tough sensed monster"] =  0 ,["thorn hunter"] =  9 ,["demonic crawler"] =  10 ,["bog body"] =  1 ,["stoker"] =  5 ,["sensed monster"] =  0 ,["wretched star"] =  10 ,["deep troll"] =  6 ,["Eustachio"] =  0 ,["elf"] =  1 ,["vampire bat"] =  1 ,["cane toad"] =  6 ,["tengu"] =  2 ,["oklob plant"] =  10 ,["skeletal warrior"] =  15 ,["swamp drake"] =  3 ,["lurking horror"] =  0 ,["player ghost"] =  1 ,["iron troll"] =  20 ,["ushabti"] =  9 ,["Erica"] =  0 ,["howler monkey"] =  1 ,["blink frog"] =  0 ,["dart slug"] =  1 ,["spider"] =  0 ,["sun moth"] =  6 ,["ogre"] =  1 ,["knight"] =  5 ,["player illusion"] =  1 ,["Tzitzimitl"] =  12 ,["air elemental"] =  2 ,["walking tome"] =  0 ,["large abomination"] =  0 ,["deep elf archer"] =  0 ,["Boris"] =  12 ,["oklob sapling"] =  10}


}
