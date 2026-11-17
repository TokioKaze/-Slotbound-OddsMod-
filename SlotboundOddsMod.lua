-- Slotbound 稀有度概率 Mod (SlotboundOddsMod)
-- 作者：TokioKaze
-- 由打包器嵌入到 src/game/luck.lua 的加载器中运行：
--   chunk(originalLuckBytecode, ...)  -> 返回原 luck 模块
-- 只修改稀有度抽取概率：
--   1) 局内老虎机：src.data.constants.unitGrades.probabilities（升级研究写入的权重表）
--   2) 命运石：src.game.stone.effectiveProbs（所有命运石抽取、卡包、提示都经过它）

local MOD_VERSION = "1.3.1"
local MOD_AUTHOR = "TokioKaze"
local GAME_VERSION_TESTED = "v1.0.0(9)"
local CONFIG_NAME = "SlotboundOddsMod.ini"
local LOG_NAME = "SlotboundOddsMod.log"

local GRADES = { "normal", "advanced", "rare", "legendary", "prism" }
local GRADE_CN = {
  normal = "普通", advanced = "高级", rare = "稀有", legendary = "传说", prism = "棱彩",
}
local STONE_CN = {
  OriginStone = "起源石", MileStone = "里程石", BlessingStone = "祝福石", BreezeStone = "微风石",
  TwinStone = "双子石", SpecialStone = "特殊石", RiftStone = "裂隙石", OmenStone = "占卜石",
  MasteryStone = "熟练石", GambitStone = "胜负石", ConstellationStone = "星群石",
  SanctumStone = "圣域石", ZenithStone = "巅峰石", EclipseStone = "日蚀石", GalaxyStone = "银河石",
}

-- 职业符号（顺序与游戏内“符号”提示一致）
local SYMBOLS = { "W", "A", "S", "H", "M", "D" }
local SYMBOL_CN = { W = "战士", A = "弓手", S = "枪兵", H = "骑兵", M = "法师", D = "决斗者" }
local SYMBOL_EN = { W = "Warrior", A = "Archer", S = "Spearman", H = "Cavalry", M = "Mage", D = "Duelist" }
local JOKER_MAX = 0.05 -- 游戏代码中小丑概率的硬上限（slot.lua：math.min(0.05, chance)）

-- 预设（老虎机为目标概率%，命运石为传说/棱彩权重倍率；按“原始概率为0保持0”处理解锁）
local PRESETS = {
  { key = "original", cn = "原版", en = "Original" },
  { key = "hard", cn = "困难", en = "Hard", slot = { legendary = 1, prism = 0.3 }, stone = 1.5 },
  { key = "medium", cn = "中等", en = "Medium", slot = { legendary = 2.5, prism = 0.8 }, stone = 2.5 },
  { key = "easy", cn = "简单", en = "Easy", slot = { legendary = 5, prism = 2 }, stone = 4 },
  { key = "bliss", cn = "肉鸽纯爽", en = "Bliss", slot = { rare = 20, legendary = 15, prism = 8 }, stone = 8 },
}

local M = {}            -- 内部函数（测试用）
local log_lines = {}
local log_file = nil
local base_dir = nil
local popup_msgs = {}

------------------------------------------------------------------------
-- 日志
------------------------------------------------------------------------
local function now()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  return ok and s or "?"
end

local function log(level, msg)
  local line = "[" .. now() .. "] [" .. level .. "] " .. tostring(msg)
  if log_file then
    pcall(function() log_file:write(line, "\n"); log_file:flush() end)
  else
    log_lines[#log_lines + 1] = line
  end
  if print then pcall(print, "[SlotboundOddsMod] " .. tostring(msg)) end
end
local function info(m) log("信息", m) end
local function warn(m) log("警告", m) end
local function err(m) log("错误", m); popup_msgs[#popup_msgs + 1] = tostring(m) end
M.log = log

local function pct(x)
  if x == nil then return "-" end
  local v = x * 100
  if v == 0 then return "0%" end
  if v >= 1 then return string.format("%.2f%%", v) end
  return string.format("%.4f%%", v)
end

local function fmt_table(t)
  local parts = {}
  for _, g in ipairs(GRADES) do
    parts[#parts + 1] = GRADE_CN[g] .. " " .. pct(t[g])
  end
  return table.concat(parts, " / ")
end
M.fmt_table = fmt_table

------------------------------------------------------------------------
-- 定位游戏目录
------------------------------------------------------------------------
local function dir_of(path)
  if type(path) ~= "string" then return nil end
  local d = path:match("^(.*)[/\\][^/\\]*$")
  return d
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function find_base_dirs()
  local cands = {}
  -- 1) exe 所在目录（FFI）
  pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "unsigned long __stdcall GetModuleFileNameA(void *hModule, char *lpFilename, unsigned long nSize);")
    local buf = ffi.new("char[1024]")
    local n = ffi.C.GetModuleFileNameA(nil, buf, 1024)
    if n and n > 0 then
      local d = dir_of(ffi.string(buf, n))
      if d then cands[#cands + 1] = d end
    end
  end)
  -- 2) LÖVE 提供的源目录
  pcall(function()
    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
      local d = love.filesystem.getSourceBaseDirectory()
      if type(d) == "string" and d ~= "" then cands[#cands + 1] = d end
    end
  end)
  -- 3) 当前工作目录
  cands[#cands + 1] = "."
  -- 4) 存档目录（最后备选，用于写日志）
  pcall(function()
    if love and love.filesystem and love.filesystem.getSaveDirectory then
      local d = love.filesystem.getSaveDirectory()
      if type(d) == "string" and d ~= "" then cands[#cands + 1] = d end
    end
  end)
  return cands
end

------------------------------------------------------------------------
-- 配置解析与校验
------------------------------------------------------------------------
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local MODE_ALIASES = {
  off = "off", ["关闭"] = "off", ["原版"] = "off", none = "off", disabled = "off",
  multiplier = "multiplier", mult = "multiplier", ["倍率"] = "multiplier",
  target = "target", ["目标"] = "target", ["目标概率"] = "target",
}
local BOOL = {
  ["true"] = true, ["yes"] = true, ["on"] = true, ["1"] = true, ["是"] = true, ["开"] = true,
  ["false"] = false, ["no"] = false, ["off"] = false, ["0"] = false, ["否"] = false, ["关"] = false,
}

-- 解析 ini 文本 -> { [sectionLower] = { _name=原名, _line=行号, key=value(string), _lines={key=行号} } }
function M.parse_ini(text)
  local sections, order = {}, {}
  local cur = nil
  local lineno = 0
  text = text:gsub("^\239\187\191", "") -- BOM
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local line = raw:gsub("\r$", "")
    -- 去掉注释：行首 ; 或 #，以及值后面的 " ;" " #"
    local s = trim(line)
    if s ~= "" and not s:match("^[;#]") then
      s = trim((s:gsub("%s[;#].*$", "")))
      local sec = s:match("^%[(.-)%]$")
      if sec then
        sec = trim(sec)
        local key = sec:lower()
        if not sections[key] then
          sections[key] = { _name = sec, _line = lineno, _lines = {} }
          order[#order + 1] = key
        end
        cur = sections[key]
      else
        local k, v = s:match("^([^=]+)=(.*)$")
        if k then
          k = trim(k):lower(); v = trim(v)
          if not cur then
            sections["general"] = sections["general"] or { _name = "general", _line = 0, _lines = {} }
            cur = sections["general"]
          end
          cur[k] = v
          cur._lines[k] = lineno
        else
          return nil, string.format("第 %d 行无法识别：“%s”（应为 [分区] 或 键 = 值）", lineno, s)
        end
      end
    end
  end
  return sections, order
end

local function parse_number(v)
  if v == nil then return nil end
  v = trim(v)
  if v == "" then return nil end
  v = v:gsub("%%$", "")
  local n = tonumber(v)
  if n == nil then return nil, "不是数字" end
  if n ~= n then return nil, "不是有效数字(NaN)" end
  if n == math.huge or n == -math.huge then return nil, "不能是无穷大" end
  return n
end

-- 校验一个分区，返回 settings 或 nil + 错误列表
-- settings = { mode=..., mult={g=x}, target={g=frac} }
function M.validate_section(sec, label, keys, extra_known)
  keys = keys or GRADES
  local errors, warnings = {}, {}
  local s = { mode = "off", mult = {}, target = {} }
  local known = { mode = true }
  if extra_known then for k in pairs(extra_known) do known[k] = true end end
  for _, g in ipairs(keys) do known["mult_" .. g:lower()] = true; known["target_" .. g:lower()] = true end

  for k, v in pairs(sec) do
    if type(k) == "string" and k:sub(1, 1) ~= "_" and not known[k] then
      warnings[#warnings + 1] = string.format("[%s] 第 %d 行：未知参数“%s”，已忽略", label, sec._lines[k] or 0, k)
    end
  end

  local mode_raw = sec.mode
  if mode_raw == nil or mode_raw == "" then
    s.mode = "off"
  else
    local m = MODE_ALIASES[mode_raw:lower()] or MODE_ALIASES[mode_raw]
    if not m then
      errors[#errors + 1] = string.format("[%s] mode = %s 无效，只能是 off / multiplier / target（关闭 / 倍率 / 目标）", label, mode_raw)
    else
      s.mode = m
    end
  end

  -- 倍率：所有值都检查（即使当前不是倍率模式，也提前发现错误）
  for _, g in ipairs(keys) do
    local key = "mult_" .. g:lower()
    if sec[key] ~= nil and sec[key] ~= "" then
      local n, e = parse_number(sec[key])
      if n == nil then
        errors[#errors + 1] = string.format("[%s] %s = %s：%s", label, key, sec[key], e or "无效")
      elseif n < 0 then
        errors[#errors + 1] = string.format("[%s] %s = %s：倍率不能为负数", label, key, sec[key])
      else
        s.mult[g] = n
      end
    end
  end

  local tsum, tcount = 0, 0
  for _, g in ipairs(keys) do
    local key = "target_" .. g:lower()
    if sec[key] ~= nil and sec[key] ~= "" then
      local n, e = parse_number(sec[key])
      if n == nil then
        errors[#errors + 1] = string.format("[%s] %s = %s：%s", label, key, sec[key], e or "无效")
      elseif n < 0 then
        errors[#errors + 1] = string.format("[%s] %s = %s：概率不能为负数", label, key, sec[key])
      elseif n > 100 then
        errors[#errors + 1] = string.format("[%s] %s = %s：单个概率不能超过 100%%", label, key, sec[key])
      else
        s.target[g] = n / 100
        tsum = tsum + n
        tcount = tcount + 1
      end
    end
  end
  if tsum > 100 + 1e-3 then
    errors[#errors + 1] = string.format("[%s] 目标概率合计 %.4g%% 超过 100%%", label, tsum)
  end

  if s.mode == "multiplier" then
    local any = false
    for _ in pairs(s.mult) do any = true end
    if not any then warnings[#warnings + 1] = string.format("[%s] 倍率模式但没有设置任何 mult_ 参数，等同原版", label) end
  elseif s.mode == "target" then
    if tcount == 0 then warnings[#warnings + 1] = string.format("[%s] 目标概率模式但没有设置任何 target_ 参数，等同原版", label) end
    if tcount == #keys and math.abs(tsum - 100) > 0.01 then
      errors[#errors + 1] = string.format("[%s] %d 项都设置了目标概率，合计必须正好 100%%（当前 %.4g%%）", label, #keys, tsum)
    end
  end

  if #errors > 0 then return nil, errors, warnings end
  return s, errors, warnings
end

------------------------------------------------------------------------
-- 概率变换（纯函数，不修改输入）
--   base: 游戏原始权重（可未归一化）
--   返回 out(新表), notes(说明列表)
------------------------------------------------------------------------
function M.transform_keys(base, keys, names, s, respect_unlocks)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  local notes = {}
  if not s or s.mode == "off" then return out, notes end

  local p, S = {}, 0
  for _, g in ipairs(keys) do
    local v = tonumber(base[g]) or 0
    if v ~= v or v < 0 then v = 0 end
    p[g] = v; S = S + v
  end
  if S <= 0 then
    notes[#notes + 1] = "原始概率全为 0，保持原样"
    return out, notes
  end
  for _, g in ipairs(keys) do p[g] = p[g] / S end

  local res = {}
  if s.mode == "multiplier" then
    local W = 0
    for _, g in ipairs(keys) do
      local m = s.mult[g]; if m == nil then m = 1 end
      res[g] = p[g] * m; W = W + res[g]
    end
    if W <= 0 then
      notes[#notes + 1] = "倍率后所有权重都是 0，无法抽取，已保持原版概率"
      return out, notes
    end
    for _, g in ipairs(keys) do res[g] = res[g] / W end
  else -- target
    local tgt, T = {}, 0
    for _, g in ipairs(keys) do
      local t = s.target[g]
      if t ~= nil then
        if respect_unlocks and p[g] <= 0 and t > 0 then
          notes[#notes + 1] = (names[g] or g) .. " 原始概率为 0（未解锁/不产出/被禁用），保持 0%"
        else
          tgt[g] = t; T = T + t
        end
      end
    end
    local restBase = 0
    for _, g in ipairs(keys) do if tgt[g] == nil then restBase = restBase + p[g] end end
    local R = 1 - T
    if R < 0 then R = 0 end
    if restBase > 0 then
      for _, g in ipairs(keys) do
        if tgt[g] ~= nil then res[g] = tgt[g] else res[g] = R * p[g] / restBase end
      end
    else
      if T <= 0 then
        notes[#notes + 1] = "目标概率与剩余项都为 0，无法抽取，已保持原版概率"
        return out, notes
      end
      if R > 1e-9 then
        notes[#notes + 1] = string.format("其余项原始概率都是 0，剩余 %s 无处分配，已按比例放大目标概率", pct(R))
      end
      for _, g in ipairs(keys) do res[g] = (tgt[g] or 0) / T end
    end
  end
  for _, g in ipairs(keys) do out[g] = res[g] end
  return out, notes
end

function M.transform(base, s, respect_unlocks)
  return M.transform_keys(base, GRADES, GRADE_CN, s, respect_unlocks)
end

------------------------------------------------------------------------
-- 配置加载
------------------------------------------------------------------------
local CFG = {
  enabled = true, respect_unlocks = true, show_error_popup = true,
  slot = nil, stone_default = nil, stone = {},
  symbols = nil, preset = nil,
}
M.CFG = CFG
M.PRESETS = PRESETS
M.SYMBOLS = SYMBOLS

local function find_preset(name)
  if not name then return nil end
  local l = tostring(name):lower()
  for _, p in ipairs(PRESETS) do
    if p.key == l or p.cn == name or p.en:lower() == l then return p end
  end
  return nil
end

-- 应用预设：覆盖 [slot] 与 [stone]，清除单块石头的单独设置（符号设置不受影响）
function M.apply_preset(name)
  local p = find_preset(name)
  if not p then return false end
  CFG.preset = p.key
  CFG.stone = {}
  if not p.slot then
    CFG.slot = { mode = "off", mult = {}, target = {} }
    CFG.stone_default = { mode = "off", mult = {}, target = {} }
  else
    local t = {}
    for g, v in pairs(p.slot) do t[g] = v / 100 end
    CFG.slot = { mode = "target", mult = {}, target = t }
    CFG.stone_default = { mode = "multiplier", mult = { legendary = p.stone, prism = p.stone }, target = {} }
  end
  if M.slot_invalidate then M.slot_invalidate() end
  return true, p
end

local function stone_key_from_label(name)
  if STONE_CN[name] then return name end
  local lower = name:lower()
  for k, cn in pairs(STONE_CN) do
    if k:lower() == lower or cn == name then return k end
  end
  return nil
end

function M.load_config_text(text)
  local sections, order_or_err = M.parse_ini(text)
  if not sections then
    err("配置文件格式错误：" .. order_or_err .. "。Mod 已停用，游戏使用原版概率。")
    CFG.enabled = false
    return false
  end
  local ok_all = true
  CFG.slot, CFG.stone_default, CFG.stone = nil, nil, {}
  local g = sections["general"] or {}
  for _, k in ipairs({ "enabled", "respect_unlocks", "show_error_popup" }) do
    if g[k] ~= nil then
      local b = BOOL[g[k]:lower()]
      if b == nil then
        err(string.format("[general] %s = %s 无效，应为 true 或 false", k, g[k])); ok_all = false
      else
        CFG[k] = b
      end
    end
  end

  local function load_sec(key, label)
    local sec = sections[key]
    if not sec then return nil end
    local s, errs, warns = M.validate_section(sec, label)
    for _, w in ipairs(warns) do warn(w) end
    if not s then
      for _, e in ipairs(errs) do err(e) end
      err("[" .. label .. "] 配置无效，该部分已回退为原版概率。")
      ok_all = false
      return nil
    end
    return s
  end

  CFG.preset = nil
  if g.preset ~= nil and g.preset ~= "" then
    local ok = M.apply_preset(g.preset)
    if not ok then
      warn("[general] preset = " .. g.preset .. " 无效，可用：原版/困难/中等/简单/肉鸽纯爽（original/hard/medium/easy/bliss）")
    else
      info("已应用预设：" .. find_preset(g.preset).cn)
    end
  end
  if sections["slot"] then CFG.slot = load_sec("slot", "slot") or { mode = "off", mult = {}, target = {} } end
  if sections["stone"] then CFG.stone_default = load_sec("stone", "stone") or { mode = "off", mult = {}, target = {} } end
  -- 符号概率（只支持目标概率模式）
  CFG.symbols = nil
  local ss = sections["symbols"]
  if ss then
    local st, errs, warns = M.validate_section(ss, "symbols", SYMBOLS, { joker = true })
    for _, w in ipairs(warns) do warn(w) end
    if st and st.mode == "multiplier" then
      errs = { "[symbols] 符号概率只支持 mode = target（目标概率）或 off" }; st = nil
    end
    if st and ss.joker ~= nil and ss.joker ~= "" then
      local n, e = parse_number(ss.joker)
      if n == nil then errs = { "[symbols] joker = " .. ss.joker .. "：" .. (e or "无效") }; st = nil
      elseif n < 0 then errs = { "[symbols] joker 不能为负数" }; st = nil
      else
        if n > JOKER_MAX * 100 then warn("[symbols] joker = " .. ss.joker .. "% 超过游戏上限 5%，按 5% 处理"); n = JOKER_MAX * 100 end
        st.joker = n / 100
      end
    end
    if not st then
      for _, e in ipairs(errs or {}) do err(e) end
      err("[symbols] 配置无效，符号概率保持原版。")
      ok_all = false
    end
    CFG.symbols = st
  end
  for key, sec in pairs(sections) do
    local name = key:match("^stone%.(.+)$")
    if name then
      local sk = stone_key_from_label(sec._name:match("^[Ss][Tt][Oo][Nn][Ee]%.(.+)$") or name)
      if not sk then
        warn("未知的命运石分区 [" .. sec._name .. "]，已忽略。可用名称：OriginStone/起源石 等，见配置文件说明")
      else
        CFG.stone[sk] = load_sec(key, sec._name) or { mode = "off", mult = {}, target = {}, _invalid = true }
      end
    elseif key ~= "general" and key ~= "slot" and key ~= "stone" and key ~= "symbols" then
      warn("未知分区 [" .. sec._name .. "]，已忽略")
    end
  end
  return ok_all
end

local function describe(s)
  if not s then return "未配置（原版）" end
  if s.mode == "off" then return "关闭（原版）" end
  local parts = {}
  if s.mode == "multiplier" then
    for _, g in ipairs(GRADES) do
      if s.mult[g] ~= nil then parts[#parts + 1] = GRADE_CN[g] .. "权重×" .. s.mult[g] end
    end
    return "倍率模式：" .. (#parts > 0 and table.concat(parts, "，") or "无") .. "（权重倍率≠最终概率倍率，见下方最终概率）"
  end
  for _, g in ipairs(GRADES) do
    if s.target[g] ~= nil then parts[#parts + 1] = GRADE_CN[g] .. "=" .. pct(s.target[g]) end
  end
  return "目标概率模式：" .. (#parts > 0 and table.concat(parts, "，") or "无") .. "，其余按原比例分配"
end
M.describe = describe

local stone_done = false
function M.try_stone()
  if stone_done then return true end
  local S = package.loaded and package.loaded["src.game.stone"]
  if type(S) == "table" then
    stone_done = true
    local ok, e = pcall(M.patch_stone, S)
    if not ok then warn("命运石挂接失败：" .. tostring(e)) end
    return true
  end
  return false
end

------------------------------------------------------------------------
-- 局内老虎机：代理 constants.unitGrades.probabilities
------------------------------------------------------------------------
function M.install_slot_proxy(probs, label)
  if getmetatable(probs) ~= nil then
    warn(label .. " 概率表已有元表，跳过（可能已安装或游戏版本变化）")
    return false
  end
  local shadow = {}
  for k, v in pairs(probs) do shadow[k] = v end
  for k in pairs(shadow) do rawset(probs, k, nil) end
  local cache, dirty = nil, true
  local last_logged = nil
  -- 游戏的升级函数（upgrade.lua）先写 advanced/rare/legendary/prism，
  -- 再读回 advanced 计算 normal = 1 - advanced - ...，最后写 normal。
  -- 在“写入 advanced”到“写入 normal”之间，读取返回原始值，保证游戏算出的原始 normal 正确。
  local writing = false

  local function rebuild()
    local out, notes = M.transform(shadow, CFG.enabled and CFG.slot or nil, CFG.respect_unlocks)
    cache = out; dirty = false
    local sig = fmt_table(shadow)
    if sig ~= last_logged then
      last_logged = sig
      info("局内老虎机 原始概率：" .. fmt_table(M.normalized(shadow)))
      info("局内老虎机 修改后  ：" .. fmt_table(out) .. "    设置：" .. describe(CFG.enabled and CFG.slot or nil))
      for _, n in ipairs(notes) do warn("局内老虎机：" .. n) end
    end
  end

  setmetatable(probs, {
    __index = function(_, k)
      if not stone_done then pcall(M.try_stone) end
      if writing then
        if k == "advanced" then return shadow[k] end
        writing = false -- 读取其他键，说明写入过程已结束（保险）
      end
      if dirty then rebuild() end
      local v = cache[k]
      if v == nil then v = shadow[k] end
      return v
    end,
    __newindex = function(_, k, v)
      if k == "advanced" then writing = true elseif k == "normal" then writing = false end
      if shadow[k] ~= v then dirty = true end
      shadow[k] = v
    end,
  })
  M._slot_shadow = shadow
  M.slot_invalidate = function() dirty = true; last_logged = nil end
  return true
end

------------------------------------------------------------------------
-- 符号概率：代理 constants.slot 的 symbolWeights 键
--   游戏（slot.lua）每次抽符号都读 constants.slot.symbolWeights；
--   某些核心会整表替换它（先复制、修改、写回，结束后再写回备份），
--   所以代理“键”而不是代理某张表。符号只用目标概率模式（可重复套用，结果不变）。
------------------------------------------------------------------------
function M.symbol_settings()
  if not CFG.enabled then return nil end
  local st = CFG.symbols
  if not st or st.mode ~= "target" then return nil end
  return st
end

function M.install_symbol_proxy(slotT)
  if type(slotT) ~= "table" then return false end
  if getmetatable(slotT) ~= nil then
    warn("constants.slot 已有元表，符号概率未修改")
    return false
  end
  local held = rawget(slotT, "symbolWeights")
  if type(held) ~= "table" then
    warn("找不到 constants.slot.symbolWeights（游戏可能已更新），符号概率未修改")
    return false
  end
  rawset(slotT, "symbolWeights", nil)
  local seen_sig, seen_n = {}, 0
  setmetatable(slotT, {
    __index = function(_, k)
      if k ~= "symbolWeights" then return nil end
      local st = M.symbol_settings()
      if not st or type(held) ~= "table" then return held end
      local out, notes = M.transform_keys(held, SYMBOLS, SYMBOL_CN, st, true)
      -- 核心（如幻影）会在每次旋转前后来回替换整张权重表，同样的组合只记录一次，避免日志刷屏
      local sig = M.fmt_keys(M.normalized_keys(held, SYMBOLS), SYMBOLS, SYMBOL_CN) .. "→" .. M.fmt_keys(out, SYMBOLS, SYMBOL_CN)
      if not seen_sig[sig] and seen_n < 60 then
        seen_sig[sig] = true; seen_n = seen_n + 1
        info("符号概率 原始：" .. M.fmt_keys(M.normalized_keys(held, SYMBOLS), SYMBOLS, SYMBOL_CN))
        info("符号概率 修改后：" .. M.fmt_keys(out, SYMBOLS, SYMBOL_CN))
        for _, n in ipairs(notes) do warn("符号概率：" .. n) end
      end
      return out
    end,
    __newindex = function(t, k, v)
      if k == "symbolWeights" then held = v else rawset(t, k, v) end
    end,
  })
  M.symbol_base = function() return held end
  return true
end

-- 小丑：游戏每次旋转用 cores.prepareSpin 算出的 jokerChance（无则用 cores.getJokerChance），上限 5%
local wrapped_gjc, wrapped_prep = nil, nil
function M.joker_override()
  local st = M.symbol_settings()
  if st and st.joker ~= nil then return math.max(0, math.min(JOKER_MAX, st.joker)) end
  return nil
end
function M.ensure_joker_hooks()
  local C = package.loaded and package.loaded["src.game.cores"]
  if type(C) ~= "table" then return end
  if type(C.getJokerChance) == "function" and C.getJokerChance ~= wrapped_gjc then
    local orig = C.getJokerChance
    wrapped_gjc = function(...)
      local o = M.joker_override()
      if o ~= nil then return o end
      return orig(...)
    end
    C.getJokerChance = wrapped_gjc
    info("已挂接小丑概率 cores.getJokerChance")
  end
  if type(C.prepareSpin) == "function" and C.prepareSpin ~= wrapped_prep then
    local orig = C.prepareSpin
    wrapped_prep = function(...)
      local r = orig(...)
      local o = M.joker_override()
      if o ~= nil and type(r) == "table" then r.jokerChance = o end
      -- 必出小丑连线：用游戏自带的 forceJokerCells（核心用的同一机制）把中间一行 3 格放小丑。
      -- 游戏判线规则：一条线 3 个都是小丑才算“小丑线”，会召唤小丑单位（解锁图鉴 R1:J）
      if type(r) == "table" and M.CH and M.CH.joker_line then
        local cells = {}
        if type(r.forceJokerCells) == "table" then for _, c in ipairs(r.forceJokerCells) do cells[#cells + 1] = c end end
        for col = 1, 3 do cells[#cells + 1] = { row = 2, col = col } end
        r.forceJokerCells = cells
        info("必出小丑连线：本次旋转中间一行强制为小丑")
      end
      return r
    end
    C.prepareSpin = wrapped_prep
    info("已挂接每次旋转的小丑概率 cores.prepareSpin")
  end
end

function M.normalized_keys(t, keys)
  local out, S = {}, 0
  for _, g in ipairs(keys) do local v = tonumber(t[g]) or 0; if v > 0 then S = S + v end end
  for _, g in ipairs(keys) do
    local v = tonumber(t[g]) or 0
    out[g] = (S > 0 and v > 0) and v / S or 0
  end
  return out
end
function M.fmt_keys(t, keys, names)
  local parts = {}
  for _, g in ipairs(keys) do parts[#parts + 1] = (names[g] or g) .. " " .. pct(t[g]) end
  return table.concat(parts, " / ")
end

function M.normalized(t)
  local out, S = {}, 0
  for _, g in ipairs(GRADES) do local v = tonumber(t[g]) or 0; if v > 0 then S = S + v end end
  for _, g in ipairs(GRADES) do
    local v = tonumber(t[g]) or 0
    out[g] = (S > 0 and v > 0) and v / S or 0
  end
  return out
end

------------------------------------------------------------------------
-- 命运石：包装 stone.effectiveProbs
------------------------------------------------------------------------
local function stone_settings(key)
  if not CFG.enabled then return nil end
  if key and CFG.stone[key] then return CFG.stone[key] end
  return CFG.stone_default
end

function M.patch_stone(S)
  if type(S) ~= "table" or type(S.effectiveProbs) ~= "function" or type(S.defs) ~= "table" then
    warn("命运石模块结构与预期不符（游戏可能已更新），命运石概率未修改")
    return false
  end
  if S.__oddsmod_patched then return true end
  local key_of = {}
  for _, def in ipairs(S.defs) do
    if type(def) == "table" and type(def.probs) == "table" and def.key then
      key_of[def.probs] = def.key
    end
  end
  local orig = S.effectiveProbs
  M.stone_mod = S
  M.stone_orig_eff = orig
  local logged = {}
  S.effectiveProbs = function(probs, ...)
    local r = orig(probs, ...)
    if type(r) ~= "table" then return r end
    local key = key_of[probs]
    if not key then return r end
    local s = stone_settings(key)
    if not s or s.mode == "off" then return r end
    local ok, out, notes = pcall(M.transform, r, s, CFG.respect_unlocks)
    if not ok then
      warn("命运石概率计算出错，使用原版：" .. tostring(out))
      return r
    end
    local sig = key .. "|" .. fmt_table(r)
    if not logged[sig] then
      logged[sig] = true
      local name = (STONE_CN[key] or key) .. "(" .. key .. ")"
      info("命运石 " .. name .. " 原始：" .. fmt_table(M.normalized(r)))
      info("命运石 " .. name .. " 修改后：" .. fmt_table(out) .. "    设置：" .. describe(s))
      for _, n in ipairs(notes) do warn("命运石 " .. name .. "：" .. n) end
    end
    return out
  end
  S.__oddsmod_patched = true

  -- 启动时预先打印每块石头的预览（按当前解锁状态）
  for _, def in ipairs(S.defs) do
    if type(def) == "table" and type(def.probs) == "table" then
      pcall(S.effectiveProbs, def.probs)
    end
  end
  info("已应用到命运石：所有命运石抽取（含货架购买、任务奖励获得的命运石）、石头提示框")
  return true
end

------------------------------------------------------------------------
-- 初始化
------------------------------------------------------------------------
------------------------------------------------------------------------
-- 配置保存（游戏内面板“保存”按钮）
------------------------------------------------------------------------
local function num_str(x)
  local s = string.format("%.6f", x)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function section_text(name, st)
  local lines = { "[" .. name .. "]" }
  if not st or st._invalid then
    lines[#lines + 1] = "mode = off"
    return table.concat(lines, "\n")
  end
  lines[#lines + 1] = "mode = " .. (st.mode or "off")
  for _, g in ipairs(GRADES) do
    if st.target and st.target[g] ~= nil then
      lines[#lines + 1] = "target_" .. g .. " = " .. num_str(st.target[g] * 100) .. "    ; " .. GRADE_CN[g] .. "（%）"
    end
  end
  for _, g in ipairs(GRADES) do
    if st.mult and st.mult[g] ~= nil then
      lines[#lines + 1] = "mult_" .. g .. " = " .. num_str(st.mult[g]) .. "    ; " .. GRADE_CN[g] .. "权重倍率"
    end
  end
  return table.concat(lines, "\n")
end

function M.config_text()
  local out = {
    "; Slotbound 稀有度概率 Mod 配置（作者 TokioKaze；由游戏内 F8 面板保存，也可手动编辑；修改后重启游戏或在面板中调整）",
    "; mode: off=原版  multiplier=权重倍率(mult_xxx，权重×倍数后重新归一化，≠最终概率×倍数)",
    ";       target=目标概率(target_xxx，单位%，未写的稀有度按原比例分配剩余部分)",
    "; 稀有度: normal 普通 / advanced 高级 / rare 稀有 / legendary 传说 / prism 棱彩",
    "; 校验：不能为负数，单项不超过 100，合计不超过 100（五项都写时必须正好 100）",
    "; respect_unlocks=true：原版为 0 的稀有度（未解锁/该石头不产出）保持 0",
    "",
    "[general]",
    "; preset：原版 / 困难 / 中等 / 简单 / 肉鸽纯爽（下面的 [slot] [stone] 会覆盖预设中的对应部分）",
    "preset = " .. (CFG.preset or ""),
    "enabled = " .. tostring(CFG.enabled),
    "respect_unlocks = " .. tostring(CFG.respect_unlocks),
    "show_error_popup = " .. tostring(CFG.show_error_popup),
    "",
    "; 局内老虎机",
    section_text("slot", CFG.slot),
    "",
    "; 所有命运石的默认设置（未单独设置的石头用这里）",
    section_text("stone", CFG.stone_default),
  }
  out[#out + 1] = ""
  out[#out + 1] = "; 符号概率（只支持 target；W 战士 A 弓手 S 枪兵 H 骑兵 M 法师 D 决斗者；joker 小丑 0~5，游戏上限 5%）"
  local sy = CFG.symbols
  out[#out + 1] = "[symbols]"
  out[#out + 1] = "mode = " .. ((sy and sy.mode == "target") and "target" or "off")
  if sy then
    for _, k in ipairs(SYMBOLS) do
      if sy.target and sy.target[k] ~= nil then out[#out + 1] = "target_" .. k .. " = " .. num_str(sy.target[k] * 100) .. "    ; " .. SYMBOL_CN[k] .. "（%）" end
    end
    if sy.joker ~= nil then out[#out + 1] = "joker = " .. num_str(sy.joker * 100) .. "    ; 小丑（%）" end
  end
  local keys = {}
  for k in pairs(CFG.stone) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = ""
    out[#out + 1] = "; " .. (STONE_CN[k] or k)
    out[#out + 1] = section_text("stone." .. k, CFG.stone[k])
  end
  return table.concat(out, "\n") .. "\n"
end

function M.save_config()
  local path = M.cfg_path
  if not path then return false, "不知道配置文件路径" end
  local f, e = io.open(path, "wb")
  if not f then return false, tostring(e) end
  f:write(M.config_text())
  f:close()
  info("已从游戏内面板保存配置：" .. path)
  return true
end

------------------------------------------------------------------------
-- 游戏内设置面板（F8）
--   5 个稀有度合计始终 100%：拖动一个，其余按它们原来的相对比例自动增减
------------------------------------------------------------------------
------------------------------------------------------------------------
-- 游戏内面板：F8 稀有度/符号概率，F7 功能面板
--   风格：按游戏的像素缩放（screenScale）绘制，优先使用游戏提示框字体与游戏图标，
--   鼠标使用游戏自己的指针图片与位置，避免出现两个指针。
------------------------------------------------------------------------
local CH = {
  open = false, focus = nil, buf = "", msg = nil, msg_t = 0,
  lock = {}, lockval = {},
  free_spin = false, free_reroll = false,
  ally_god = false, ally_mult = 1, one_hit = false,
  nudge_extra = 0, inf_nudge = false, joker_line = false,
  added_credit = false, hits = {},
}
M.CH = CH

local UI = {
  open = false, tab = "slot", stone_idx = 1,
  drag = nil, msg = nil, msg_t = 0, hint_t = 15,
  hits = {}, rows = {},
}
M.UI = UI

local function pt_in(r, x, y) return r and x >= r[1] and x < r[1] + r[3] and y >= r[2] and y < r[2] + r[4] end
local function floor(x) return math.floor(x + 0.5) end

-- 把 vals（百分比 0~100）中第 idx 个设为 v，其余“可调”项按 base_vals 中的比例分配 100-v
function M.redistribute(base_vals, idx, v, enabled, fallback)
  local n = #base_vals
  local vals = {}
  for i = 1, n do vals[i] = base_vals[i] end
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  local others, n_en = 0, 0
  for i = 1, n do
    if i ~= idx and enabled[i] then others = others + base_vals[i]; n_en = n_en + 1 end
  end
  if n_en == 0 then v = 100 end
  local rem = 100 - v
  vals[idx] = v
  for i = 1, n do
    if i ~= idx then
      if not enabled[i] then
        vals[i] = 0
      elseif others > 1e-12 then
        vals[i] = base_vals[i] * rem / others
      else
        local fsum = 0
        if fallback then for j = 1, n do if j ~= idx and enabled[j] then fsum = fsum + (fallback[j] or 0) end end end
        if fsum > 1e-12 then vals[i] = (fallback[i] or 0) * rem / fsum else vals[i] = rem / n_en end
      end
    end
  end
  return vals
end

------------------------------------------------------------------------
-- 主题与绘制工具
------------------------------------------------------------------------
local COL = {
  edge = { 0.055, 0.047, 0.066, 1 },
  rim = { 0.45, 0.38, 0.48, 1 },
  rim2 = { 0.30, 0.25, 0.33, 1 },
  bg = { 0.165, 0.137, 0.184, 0.97 },
  bg2 = { 0.115, 0.098, 0.128, 1 },
  text = { 0.94, 0.90, 0.83, 1 },
  dim = { 0.60, 0.55, 0.60, 1 },
  gold = { 0.96, 0.76, 0.36, 1 },
  btn = { 0.27, 0.22, 0.30, 1 },
  btnh = { 0.36, 0.30, 0.40, 1 },
  on = { 0.27, 0.47, 0.29, 1 },
  sel = { 0.58, 0.42, 0.18, 1 },
  red = { 0.55, 0.22, 0.22, 1 },
  track = { 0.07, 0.06, 0.08, 1 },
}
local GRADE_COLORS = {
  normal = { 0.93, 0.93, 0.93 }, advanced = { 0.49, 0.86, 0.55 }, rare = { 0.45, 0.62, 1.0 },
  legendary = { 1.0, 0.60, 0.16 }, prism = { 0.95, 0.50, 0.95 },
}
local RAINBOW = { { 1, 0.45, 0.75 }, { 0.45, 0.9, 1 }, { 1, 0.85, 0.35 }, { 0.6, 1, 0.55 }, { 0.75, 0.55, 1 } }
local GRADE_EN = { normal = "Normal", advanced = "Advanced", rare = "Rare", legendary = "Legendary", prism = "Prism" }
local SYMBOL_COLOR = { 0.93, 0.90, 0.85 }

local function U()
  local sc = tonumber(rawget(_G, "screenScale"))
  if not sc or sc <= 0 then
    local _, h = love.graphics.getDimensions()
    sc = math.max(1, floor(h / 540))
  end
  return sc
end

-- 字体：优先游戏提示框字体（像素字体，按 screenScale 放大）；缺字时用系统中文字体
local FONT = { cache = {}, fb = nil, fb_px = 0, ascii_ok = nil }
local function game_font()
  local ok, f = pcall(function()
    local u = rawget(_G, "ui")
    if type(u) ~= "table" then return nil end
    local cand = (type(u.tooltip) == "table" and u.tooltip.font) or u.font
    if cand and cand.getHeight and cand.hasGlyphs then return cand end
    return nil
  end)
  if ok then return f end
  return nil
end
M._game_font = game_font

local function fallback_font(px)
  if FONT.fb and FONT.fb_px == px then return FONT.fb end
  local G = love.graphics
  if FONT.bytes == nil then
    FONT.bytes = false
    for _, p in ipairs({ "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/msyh.ttf", "C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/simsun.ttc" }) do
      local f = io.open(p, "rb")
      if f then FONT.bytes = f:read("*a"); FONT.bytes_name = p:match("([^/]+)$"); f:close(); break end
    end
  end
  local size = math.max(10, floor(px / 1.25))
  local fnt = nil
  if FONT.bytes and not FONT.sys_failed then
    local ok, r = pcall(function() return G.newFont(love.filesystem.newFileData(FONT.bytes, FONT.bytes_name), size) end)
    if ok and r then fnt = r else FONT.sys_failed = true; warn("系统中文字体加载失败：" .. tostring(r)) end
  end
  if not fnt then local ok, r = pcall(G.newFont, size); if ok then fnt = r end end
  FONT.fb, FONT.fb_px = fnt, px
  return fnt
end

-- 游戏字体的整数放大倍数：让字高约等于 11 个游戏像素（不论游戏字体是低分辨率还是已放大）
local function tscale(gf)
  local fh = gf:getHeight()
  if not fh or fh <= 0 then return 1 end
  return math.max(1, floor(11 * U() / fh))
end
local function line_h()
  local gf = game_font()
  if gf then return gf:getHeight() * tscale(gf) end
  return 11 * U()
end

local function pick_font(str)
  local gf = game_font()
  if gf then
    local ok
    if not str:find("[\128-\255]") then
      if FONT.ascii_ok == nil then
        local o, h = pcall(gf.hasGlyphs, gf, "0123456789%.,-+x/:() ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz<>|")
        FONT.ascii_ok = o and h or false
      end
      ok = FONT.ascii_ok
    else
      ok = FONT.cache[str]
      if ok == nil then
        local o, h = pcall(gf.hasGlyphs, gf, str)
        ok = o and h or false
        FONT.cache[str] = ok
      end
    end
    if ok then return gf, tscale(gf) end
  end
  return fallback_font(line_h()), 1
end

local function textw(str)
  local f, sc = pick_font(str)
  return f and f:getWidth(str) * sc or #str * 6
end

local function text(str, x, y, col, align_w, align)
  local G = love.graphics
  local f, sc = pick_font(str)
  if not f then return end
  G.setFont(f)
  local fy = y + (line_h() - f:getHeight() * sc) / 2
  local fx = x
  if align_w then
    local w = f:getWidth(str) * sc
    if align == "center" then fx = x + (align_w - w) / 2 elseif align == "right" then fx = x + align_w - w end
  end
  G.setColor(col[1], col[2], col[3], col[4] or 1)
  G.print(str, floor(fx), floor(fy), 0, sc, sc)
end

local function rainbow_text(str, x, y)
  local G = love.graphics
  local f, sc = pick_font(str)
  if not f then return end
  G.setFont(f)
  local fy = y + (line_h() - f:getHeight() * sc) / 2
  local i, cx = 0, x
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    i = i + 1
    local c = RAINBOW[(i - 1) % #RAINBOW + 1]
    G.setColor(c[1], c[2], c[3], 1)
    G.print(ch, floor(cx), floor(fy), 0, sc, sc)
    cx = cx + f:getWidth(ch) * sc
  end
end

-- 像素风边框：外描边 + 亮边 + 底色（直角）
local function frame(x, y, w, h, bg)
  local G, u = love.graphics, U()
  x, y, w, h = floor(x), floor(y), floor(w), floor(h)
  G.setColor(COL.edge); G.rectangle("fill", x, y, w, h)
  G.setColor(COL.rim); G.rectangle("fill", x + u, y + u, w - 2 * u, h - 2 * u)
  G.setColor(COL.rim2); G.rectangle("fill", x + 2 * u, y + 2 * u, w - 4 * u, h - 4 * u)
  local b = bg or COL.bg
  G.setColor(b); G.rectangle("fill", x + 3 * u, y + 3 * u, w - 6 * u, h - 6 * u)
end

local function sep(x, y, w)
  local G, u = love.graphics, U()
  G.setColor(COL.rim2); G.rectangle("fill", floor(x), floor(y), floor(w), u)
end

local MOUSE = { 0, 0 }
local function button(r, label, state, hits, id, extra)
  local G, u = love.graphics, U()
  local x, y, w, h = floor(r[1]), floor(r[2]), floor(r[3]), floor(r[4])
  local hover = pt_in(r, MOUSE[1], MOUSE[2])
  local c = COL.btn
  if state == "on" then c = COL.on elseif state == "sel" then c = COL.sel elseif state == "red" then c = COL.red end
  G.setColor(COL.edge); G.rectangle("fill", x, y, w, h)
  G.setColor(c); G.rectangle("fill", x + u, y + u, w - 2 * u, h - 2 * u)
  G.setColor(1, 1, 1, hover and 0.16 or 0.07); G.rectangle("fill", x + u, y + u, w - 2 * u, u)
  if hover then G.setColor(1, 1, 1, 0.06); G.rectangle("fill", x + u, y + u, w - 2 * u, h - 2 * u) end
  G.setColor(0, 0, 0, 0.25); G.rectangle("fill", x + u, y + h - 2 * u, w - 2 * u, u)
  text(label, x, y + (h - line_h()) / 2, (state == "dis") and COL.dim or COL.text, w, "center")
  if hits then hits[#hits + 1] = { id = id, r = r, extra = extra } end
end

-- 游戏图标（从游戏包中读取，失败则不画）
local ICONS = {}
local ICON_PATHS = {
  W = "src/sprites/icons/warrior_tooltip.png", A = "src/sprites/icons/archer_tooltip.png",
  S = "src/sprites/icons/spear_tooltip.png", H = "src/sprites/icons/horse_tooltip.png",
  M = "src/sprites/icons/mage_tooltip.png", D = "src/sprites/icons/duelist_tooltip.png",
  Joker = "src/sprites/icons/joker_tooltip.png",
  gold = "src/sprites/icons/tooltip/gold.png", essence = "src/sprites/icons/tooltip/essence.png",
  hp = "src/sprites/icons/tooltip/hp.png", atk = "src/sprites/icons/tooltip/atk.png",
}
local function icon(key)
  if ICONS[key] ~= nil then return ICONS[key] or nil end
  ICONS[key] = false
  local p = ICON_PATHS[key]
  if p then
    local ok, img = pcall(love.graphics.newImage, p)
    if ok and img then pcall(img.setFilter, img, "nearest", "nearest"); ICONS[key] = img end
  end
  return ICONS[key] or nil
end
local function draw_icon(key, x, y)
  local img = icon(key)
  if not img then return 0 end
  local u = U()
  local G = love.graphics
  local ih = img:getHeight() * u
  G.setColor(1, 1, 1, 1)
  G.draw(img, floor(x), floor(y + (line_h() - ih) / 2), 0, u, u)
  return img:getWidth() * u + 3 * u
end

local function T(cn, en) return cn end -- 中文界面（缺字时自动换用系统字体）

------------------------------------------------------------------------
-- 稀有度/符号数据
------------------------------------------------------------------------
local function current_target()
  if UI.tab == "slot" then
    local base = M._slot_shadow and M.normalized(M._slot_shadow) or nil
    return { keys = GRADES, base = base, st = CFG.slot, title = "局内老虎机", respect = CFG.respect_unlocks }
  elseif UI.tab == "symbols" then
    local b = M.symbol_base and M.symbol_base() or nil
    local base = type(b) == "table" and M.normalized_keys(b, SYMBOLS) or nil
    return { keys = SYMBOLS, base = base, st = CFG.symbols, title = "符号", respect = true }
  end
  local S = M.stone_mod
  if not S or not S.defs or #S.defs == 0 then return { keys = GRADES } end
  local n = #S.defs
  if UI.stone_idx < 1 then UI.stone_idx = n end
  if UI.stone_idx > n then UI.stone_idx = 1 end
  local def = S.defs[UI.stone_idx]
  local ok, r = pcall(M.stone_orig_eff, def.probs)
  local base = (ok and type(r) == "table") and M.normalized(r) or M.normalized(def.probs)
  local st = CFG.stone[def.key]
  if st == nil then st = CFG.stone_default end
  return { keys = GRADES, base = base, st = st, title = (STONE_CN[def.key] or def.key), key = def.key, respect = CFG.respect_unlocks }
end

local function row_state()
  local t = current_target()
  if not t.base then return nil end
  local enabled, cur = {}, {}
  local st = CFG.enabled and t.st or nil
  if st and st.mode == "off" then st = nil end
  local names = (t.keys == SYMBOLS) and SYMBOL_CN or GRADE_CN
  local eff = M.transform_keys(t.base, t.keys, names, st, t.respect)
  for i, g in ipairs(t.keys) do
    enabled[i] = (not t.respect) or (t.base[g] or 0) > 0
    cur[i] = (eff[g] or 0) * 100
  end
  t.enabled, t.cur = enabled, cur
  return t
end

local function apply_vals(rs, vals)
  local st = { mode = "target", mult = {}, target = {} }
  for i, g in ipairs(rs.keys) do st.target[g] = vals[i] / 100 end
  if UI.tab == "slot" then
    CFG.slot = st
    if M.slot_invalidate then M.slot_invalidate() end
  elseif UI.tab == "symbols" then
    st.joker = CFG.symbols and CFG.symbols.joker or nil
    CFG.symbols = st
  else
    CFG.stone[rs.key] = st
  end
  CFG.enabled = true
  CFG.preset = nil
end

local function reset_current(rs)
  if UI.tab == "slot" then
    CFG.slot = { mode = "off", mult = {}, target = {} }
    if M.slot_invalidate then M.slot_invalidate() end
  elseif UI.tab == "symbols" then
    CFG.symbols = nil
  elseif rs and rs.key then
    CFG.stone[rs.key] = { mode = "off", mult = {}, target = {} }
  end
  CFG.preset = nil
end

local function set_msg(m) UI.msg = m; UI.msg_t = 4 end
local function upct(x)
  local v = (x or 0) * 100
  if v == 0 then return "0%" end
  if v >= 10 then return string.format("%.1f%%", v) end
  if v >= 0.1 then return string.format("%.2f%%", v) end
  return string.format("%.3f%%", v)
end

------------------------------------------------------------------------
-- 鼠标：画游戏自己的指针（位置、缩放、热点与游戏完全一致），面板打开时始终在最上层
------------------------------------------------------------------------
function M.draw_cursor()
  local G = love.graphics
  local ok, mx, my = pcall(love.mouse.getPosition)
  if not ok then return end
  local ctrl = rawget(_G, "Controller")
  if type(ctrl) == "table" and ctrl.hideCursor then return end
  local img = rawget(_G, "cursorImage")
  if img and img.getWidth then
    local sx = tonumber(rawget(_G, "screenScaleX")) or tonumber(rawget(_G, "screenScale")) or U()
    local sy = tonumber(rawget(_G, "screenScaleY")) or tonumber(rawget(_G, "screenScale")) or U()
    local hx = tonumber(rawget(_G, "cursorHotspotX")) or 0
    local hy = tonumber(rawget(_G, "cursorHotspotY")) or 0
    G.setColor(1, 1, 1, 1); G.setShader()
    G.draw(img, math.floor(mx - hx * sx + 0.5), math.floor(my - hy * sy + 0.5), 0, sx, sy)
    return
  end
  -- 备用：像素箭头
  local u = U()
  local px = { "X", "XX", "XWX", "XWWX", "XWWWX", "XWWWWX", "XWWWWWX", "XWWWXXXX", "XWXWX", "XX XWX", "    XWX", "     XX" }
  for r, line in ipairs(px) do
    for c = 1, #line do
      local ch = line:sub(c, c)
      if ch == "X" then G.setColor(0.1, 0.08, 0.12, 1) elseif ch == "W" then G.setColor(0.95, 0.9, 0.8, 1) end
      if ch ~= " " then G.rectangle("fill", mx + (c - 1) * u, my + (r - 1) * u, u, u) end
    end
  end
end

------------------------------------------------------------------------
-- F8 面板
------------------------------------------------------------------------
local function odds_panel_rect()
  local G = love.graphics
  local w, h = G.getDimensions()
  local u = U()
  local pw = 346 * u
  return floor(math.max(8 * u, 20 * u)), nil, pw
end

function M.draw_odds()
  local G = love.graphics
  local u, L = U(), line_h()
  local w, h = G.getDimensions()
  local hits = {}
  UI.hits, UI.rows = hits, {}

  if not UI.open then
    if UI.hint_t > 0 then
      local t = "概率 Mod v" .. MOD_VERSION .. "（作者 " .. MOD_AUTHOR .. "）已加载 · F8 稀有度/符号概率 · F7 功能面板"
      local tw = textw(t) + 12 * u
      frame(6 * u, 6 * u, tw, L + 10 * u, COL.bg2)
      text(t, 12 * u, 11 * u, COL.gold)
    end
    return
  end

  local rs = row_state()
  local pad = 8 * u
  local px, _, pw = odds_panel_rect()
  local rowH = math.max(L, 10 * u) + 6 * u
  local nrows = rs and #rs.keys or 5
  local ph = pad * 2 + L + 6 * u          -- 标题
    + (L + 8 * u) + 6 * u                 -- 预设
    + (L + 8 * u) + 8 * u                 -- 页签
    + ((UI.tab == "stone") and (L + 10 * u) or 0)
    + nrows * rowH
    + ((UI.tab == "symbols") and (rowH + 8 * u) or 0)
    + 8 * u + (L + 8 * u) + 6 * u + L * 2 + 4 * u
  local py = floor(math.max(4 * u, (h - ph) / 2))
  UI.panel = { px, py, pw, ph }
  frame(px, py, pw, ph)
  local x0, x1 = px + pad, px + pw - pad
  local y = py + pad

  -- 标题 + 总开关
  text("稀有度 / 符号概率", x0, y, COL.gold)
  text("by " .. MOD_AUTHOR, x0 + textw("稀有度 / 符号概率") + 6 * u, y, COL.dim)
  local tgw = 64 * u
  button({ x1 - tgw, y - 2 * u, tgw, L + 4 * u }, CFG.enabled and "Mod：开" or "Mod：关", CFG.enabled and "on" or "red", hits, "toggle")
  y = y + L + 4 * u
  sep(x0, y, x1 - x0); y = y + 2 * u + 4 * u

  -- 预设
  text("预设", x0, y + 4 * u, COL.dim)
  local lw = textw("预设") + 6 * u
  local gap = 3 * u
  local bw = (x1 - x0 - lw - gap * (#PRESETS - 1)) / #PRESETS
  for i, p in ipairs(PRESETS) do
    button({ x0 + lw + (i - 1) * (bw + gap), y, bw, L + 8 * u }, p.cn, (CFG.preset == p.key) and "sel" or nil, hits, "preset", p.key)
  end
  y = y + L + 8 * u + 6 * u

  -- 页签
  local tabs = { { "slot", "老虎机稀有度" }, { "stone", "命运石稀有度" }, { "symbols", "符号概率" } }
  local tw2 = (x1 - x0 - 2 * gap) / 3
  for i, tb in ipairs(tabs) do
    button({ x0 + (i - 1) * (tw2 + gap), y, tw2, L + 8 * u }, tb[2], UI.tab == tb[1] and "sel" or nil, hits, "tab", tb[1])
  end
  y = y + L + 8 * u + 8 * u

  if not rs then
    text(UI.tab == "stone" and "命运石模块尚未加载（进入一次游戏后再试）" or "概率表尚未挂接", x0, y, { 1, 0.6, 0.5 })
    return
  end

  if UI.tab == "stone" then
    local ab = 14 * u
    button({ x0, y, ab, L + 6 * u }, "<", nil, hits, "prev")
    button({ x0 + 120 * u, y, ab, L + 6 * u }, ">", nil, hits, "next")
    text(rs.title, x0 + ab, y + 3 * u, COL.text, 120 * u - ab, "center")
    text(CFG.stone[rs.key] ~= nil and "单独设置" or "使用默认设置", x0 + 140 * u, y + 3 * u, COL.dim)
    y = y + L + 10 * u
  end

  -- 滑条行
  local labelW, trackW, valW, sb = 50 * u, 132 * u, 40 * u, 11 * u
  local fb = {}
  for i, g in ipairs(rs.keys) do fb[i] = (rs.base[g] or 0) * 100 end
  for i, g in ipairs(rs.keys) do
    local en = rs.enabled[i]
    local ry = y
    -- 名称
    if rs.keys == SYMBOLS then
      local iw = draw_icon(g, x0, ry)
      text(SYMBOL_CN[g], x0 + iw, ry, en and SYMBOL_COLOR or COL.dim)
    elseif g == "prism" and en then
      rainbow_text(GRADE_CN[g], x0, ry)
    else
      local c = GRADE_COLORS[g]
      text(GRADE_CN[g], x0, ry, en and c or COL.dim)
    end
    -- 滑条
    local tx, th = x0 + labelW, 4 * u
    local ty = ry + floor((L - th) / 2)
    G.setColor(COL.edge); G.rectangle("fill", tx - u, ty - u, trackW + 2 * u, th + 2 * u)
    G.setColor(COL.track); G.rectangle("fill", tx, ty, trackW, th)
    local v = rs.cur[i]
    local c = (rs.keys == SYMBOLS) and COL.gold or GRADE_COLORS[g]
    if en then
      G.setColor(c[1], c[2], c[3], 0.95)
      G.rectangle("fill", tx, ty, floor(trackW * v / 100), th)
    end
    local bx = tx + floor(trackW * fb[i] / 100)
    G.setColor(1, 1, 1, 0.55); G.rectangle("fill", bx, ty - 2 * u, u, th + 4 * u)
    local kx = tx + floor(trackW * v / 100) - floor(1.5 * u)
    G.setColor(COL.edge); G.rectangle("fill", kx - u, ty - 3 * u, 5 * u, th + 6 * u)
    G.setColor(en and COL.text or COL.dim); G.rectangle("fill", kx, ty - 2 * u, 3 * u, th + 4 * u)
    -- 数值与按钮
    local vx = tx + trackW + 6 * u
    text(upct(v / 100), vx, ry, en and COL.text or COL.dim, valW, "right")
    local mb = { vx + valW + 4 * u, ry - 1 * u, sb, L + 2 * u }
    local pb = { mb[1] + sb + 2 * u, ry - 1 * u, sb, L + 2 * u }
    button(mb, "-", en and nil or "dis", hits, "minus", i)
    button(pb, "+", en and nil or "dis", hits, "plus", i)
    text(en and ("原" .. upct(fb[i] / 100)) or (rs.keys == SYMBOLS and "已禁用" or "未解锁"), pb[1] + sb + 4 * u, ry, COL.dim)
    UI.rows[i] = { bar = { tx - 2 * u, ry - 3 * u, trackW + 4 * u, L + 6 * u }, row = { x0, ry - 3 * u, x1 - x0, rowH }, enabled = en, tx = tx, tw = trackW }
    y = y + rowH
  end

  -- 小丑（符号页）
  if UI.tab == "symbols" then
    y = y + 2 * u
    sep(x0, y, x1 - x0); y = y + 6 * u
    local jo = M.joker_override()
    local jv = (jo or 0) * 100
    local iw = draw_icon("Joker", x0, y)
    text("小丑", x0 + iw, y, COL.text)
    local tx, th = x0 + labelW, 4 * u
    local ty = y + floor((L - th) / 2)
    G.setColor(COL.edge); G.rectangle("fill", tx - u, ty - u, trackW + 2 * u, th + 2 * u)
    G.setColor(COL.track); G.rectangle("fill", tx, ty, trackW, th)
    G.setColor(0.75, 0.5, 1, 0.95); G.rectangle("fill", tx, ty, floor(trackW * jv / 5), th)
    local kx = tx + floor(trackW * jv / 5) - floor(1.5 * u)
    G.setColor(COL.edge); G.rectangle("fill", kx - u, ty - 3 * u, 5 * u, th + 6 * u)
    G.setColor(COL.text); G.rectangle("fill", kx, ty - 2 * u, 3 * u, th + 4 * u)
    local vx = tx + trackW + 6 * u
    text(jo and upct(jo) or "原版", vx, y, COL.text, valW, "right")
    local mb = { vx + valW + 4 * u, y - u, sb, L + 2 * u }
    local pb = { mb[1] + sb + 2 * u, y - u, sb, L + 2 * u }
    button(mb, "-", nil, hits, "jminus")
    button(pb, "+", nil, hits, "jplus")
    text("上限 5%", pb[1] + sb + 4 * u, y, COL.dim)
    UI.joker_row = { bar = { tx - 2 * u, y - 3 * u, trackW + 4 * u, L + 6 * u }, row = { x0, y - 3 * u, x1 - x0, rowH }, tx = tx, tw = trackW }
    y = y + rowH
  else
    UI.joker_row = nil
  end

  -- 底部
  y = y + 2 * u
  sep(x0, y, x1 - x0); y = y + 6 * u
  local half = (x1 - x0 - 4 * u) / 2
  button({ x0, y, half, L + 8 * u }, "恢复原版（本页）", "red", hits, "reset")
  button({ x0 + half + 4 * u, y, half, L + 8 * u }, "保存到配置文件", "on", hits, "save")
  y = y + L + 8 * u + 6 * u
  text(UI.tab == "symbols" and "六种职业合计 100%；小丑先于职业判定，游戏上限 5%" or "合计始终 100%：拖动一个，其余按原比例增减", x0, y, COL.dim)
  y = y + L + 2 * u
  if UI.msg then text(UI.msg, x0, y, COL.gold) else text("滚轮 / ± 调整 0.1%，按住 Shift 为 1%", x0, y, COL.dim) end
end

------------------------------------------------------------------------
-- F7 面板
------------------------------------------------------------------------
local function bf() return rawget(_G, "battlefield") end
local function gui() return rawget(_G, "ui") end
local function in_run()
  local b = bf()
  return type(b) == "table" and rawget(_G, "phase") ~= "menu"
end

local VALUES = {
  { key = "coins", cn = "金币", icon = "gold",
    get = function() return tonumber(rawget(_G, "coins")) end,
    set = function(v) rawset(_G, "coins", v); rawset(_G, "displayCoins", v) end },
  { key = "jungsu", cn = "蓝色精华", icon = "essence",
    get = function() return tonumber(rawget(_G, "jungsu")) end,
    set = function(v)
      rawset(_G, "jungsu", v); rawset(_G, "displayJungsu", v)
      local u = gui(); if type(u) == "table" then u.jungsuBalance = v; u.jungsuBalanceTarget = v end
    end },
  { key = "spins", cn = "剩余旋转", icon = nil,
    get = function() return tonumber(rawget(_G, "spinsLeft")) end,
    set = function(v) rawset(_G, "spinsLeft", v) end },
  { key = "hearts", cn = "红心", icon = "hp",
    get = function() local b = bf(); return type(b) == "table" and tonumber(b.baseHP) or nil end,
    set = function(v) local b = bf(); if type(b) == "table" then b.baseHP = v; b._prevBaseHP = v end end },
  { key = "nudge", cn = "额外微调", icon = nil,
    get = function() return CH.nudge_extra end,
    set = function(v) CH.nudge_extra = v end, nolock = true },
  { key = "mult", cn = "伤害倍率", icon = "atk",
    get = function() return CH.ally_mult end,
    set = function(v) CH.ally_mult = v end, nolock = true, decimal = true },
}
M.CH_VALUES = VALUES

local TOGGLES = {
  { key = "free_spin", cn = "免费旋转" },
  { key = "free_reroll", cn = "免费重掷" },
  { key = "inf_nudge", cn = "无限微调" },
  { key = "joker_line", cn = "必出小丑连线" },
  { key = "ally_god", cn = "小兵无限血量" },
  { key = "one_hit", cn = "一击必杀" },
}

local function ch_msg(m) CH.msg = m; CH.msg_t = 4 end

function M.cur_wave_id()
  local b = bf()
  if type(b) ~= "table" then return nil end
  local w = (type(b.wave) == "table" and tonumber(b.wave.id)) or 0
  if b.gameOver then return math.max(1, w) end
  local active = type(b.wave) == "table" and b.wave.active == true
  return math.max(1, active and w or (w + 1))
end

local wrapped_ally, wrapped_enemy = nil, nil
local function ensure_damage_hooks()
  local fa = rawget(_G, "__slotModifyBossDamageToAlly")
  if type(fa) == "function" and fa ~= wrapped_ally then
    local orig = fa
    wrapped_ally = function(ally, attacker, dmg, ...)
      local r = orig(ally, attacker, dmg, ...)
      if CH.ally_god then return 0 end
      return r
    end
    rawset(_G, "__slotModifyBossDamageToAlly", wrapped_ally)
    info("已挂接对小兵伤害钩子 __slotModifyBossDamageToAlly")
  end
  local fe = rawget(_G, "__slotModifyBossDamageToEnemy")
  if type(fe) == "function" and fe ~= wrapped_enemy then
    local orig = fe
    wrapped_enemy = function(enemy, attacker, dmg, ...)
      local r = orig(enemy, attacker, dmg, ...)
      local n = tonumber(r)
      if not n then return r end
      local m = tonumber(CH.ally_mult) or 1
      if m ~= 1 and m >= 0 then n = n * m end
      if CH.one_hit and type(enemy) == "table" then
        local need = (tonumber(enemy.hp) or 0) + (tonumber(enemy.shield) or 0) + 1
        if n < need then n = need end
      end
      return n
    end
    rawset(_G, "__slotModifyBossDamageToEnemy", wrapped_enemy)
    info("已挂接对敌伤害钩子 __slotModifyBossDamageToEnemy")
  end
end

function M.cheat_tick()
  ensure_damage_hooks()
  if not in_run() then return end
  for _, f in ipairs(VALUES) do
    if CH.lock[f.key] and CH.lockval[f.key] ~= nil then
      local cur = f.get()
      if cur ~= CH.lockval[f.key] then f.set(CH.lockval[f.key]) end
    end
  end
  if CH.free_spin then
    local c = tonumber(rawget(_G, "freeSpinCredits")) or 0
    if c < 1 then rawset(_G, "freeSpinCredits", 1); CH.added_credit = true end
  end
  local u = gui()
  if CH.free_reroll then
    if type(u) == "table" then
      u._freeRerollPending = true
      u._stoneRerollUsed = nil
    end
    local c = tonumber(rawget(_G, "coreFreeRerollsRemaining")) or 0
    if c < 1 then rawset(_G, "coreFreeRerollsRemaining", 1) end
  end
  -- 微调：游戏判定“本波已用”= ui._nudgeUsedWaveId 等于当前波次 ID（main.lua 中的波次函数：
  -- battlefield.wave.id，准备阶段算下一波）；“本次旋转已用”同理看 _nudgeUsedSpinWaveId
  if type(u) == "table" then
    local wid = M.cur_wave_id()
    local used = wid ~= nil and tonumber(u._nudgeUsedWaveId) == wid
    local spin_used = wid ~= nil and tonumber(u._nudgeUsedSpinWaveId) == wid
    if used or spin_used then
      if CH.inf_nudge then
        u._nudgeUsedWaveId = nil; u._nudgeUsedSpinWaveId = nil; u._nudgeUsedSpinIndex = nil
      elseif (tonumber(CH.nudge_extra) or 0) > 0 then
        u._nudgeUsedWaveId = nil; u._nudgeUsedSpinWaveId = nil; u._nudgeUsedSpinIndex = nil
        CH.nudge_extra = CH.nudge_extra - 1
        info("额外微调：本波微调已恢复，剩余额外次数 " .. CH.nudge_extra)
      end
    end
  end
  if CH.ally_god then
    local b = bf()
    if type(b) == "table" and type(b.allies) == "table" then
      for _, a in ipairs(b.allies) do
        if type(a) == "table" and a.alive ~= false and not a.dying then
          local mx = tonumber(a.maxhp)
          if mx and (tonumber(a.hp) or 0) < mx then a.hp = mx end
        end
      end
    end
  end
end

local function fmt_val(v, decimal)
  if v == nil then return "-" end
  if decimal then
    local s = string.format("%.2f", v); s = s:gsub("0+$", ""):gsub("%.$", ""); return s
  end
  return tostring(math.floor(v + 0.5))
end

function M.draw_cheat()
  local G = love.graphics
  local u, L = U(), line_h()
  local w, h = G.getDimensions()
  local hits = {}
  CH.hits = hits
  local pad = 8 * u
  local pw = 230 * u
  local rowH = L + 10 * u
  local ph = pad * 2 + L + 6 * u + (L + 6 * u) + 5 * rowH + 6 * u + (L + 6 * u) + rowH + 6 * u + math.ceil(#TOGGLES / 2) * (L + 10 * u) + 6 * u + 2 * L + 4 * u
  local px = floor(w - pw - 20 * u)
  local py = floor(math.max(4 * u, (h - ph) / 2))
  CH.panel = { px, py, pw, ph }
  frame(px, py, pw, ph)
  local x0, x1 = px + pad, px + pw - pad
  local y = py + pad
  text("功能面板", x0, y, COL.gold)
  text("by " .. MOD_AUTHOR, x0 + textw("功能面板") + 6 * u, y, COL.dim)
  text("F7 关闭", x0, y, COL.dim, x1 - x0, "right")
  y = y + L + 4 * u
  sep(x0, y, x1 - x0); y = y + 2 * u + 4 * u
  local running = in_run()
  text(running and "玩家" or "玩家（进入一局后才能修改）", x0, y, running and COL.dim or { 1, 0.65, 0.5 })
  y = y + L + 6 * u
  local labelW, boxW, bw = 62 * u, 56 * u, 34 * u
  for i, f in ipairs(VALUES) do
    if f.key == "mult" then
      y = y + 2 * u
      sep(x0, y, x1 - x0); y = y + 4 * u
      text("小兵", x0, y, COL.dim)
      y = y + L + 6 * u
    end
    local iw = f.icon and draw_icon(f.icon, x0, y + 3 * u) or 0
    text(f.cn, x0 + iw, y + 3 * u, COL.text)
    local box = { x0 + labelW, y, boxW, L + 6 * u }
    local focused = CH.focus == i
    G.setColor(COL.edge); G.rectangle("fill", box[1], box[2], box[3], box[4])
    G.setColor(focused and COL.gold or COL.rim2); G.rectangle("fill", box[1] + u, box[2] + u, box[3] - 2 * u, box[4] - 2 * u)
    G.setColor(COL.track); G.rectangle("fill", box[1] + 2 * u, box[2] + 2 * u, box[3] - 4 * u, box[4] - 4 * u)
    local blink = (math.floor((love.timer and love.timer.getTime() or 0) * 2) % 2 == 0) and "_" or ""
    local shown = focused and (CH.buf .. blink) or fmt_val(f.get(), f.decimal)
    text(shown, box[1] + 4 * u, box[2] + 3 * u, focused and COL.gold or COL.text)
    hits[#hits + 1] = { id = "box", r = box, extra = i }
    button({ box[1] + boxW + 4 * u, y, bw, L + 6 * u }, "应用", nil, hits, "apply", i)
    if not f.nolock then
      button({ box[1] + boxW + 8 * u + bw, y, bw, L + 6 * u }, CH.lock[f.key] and "已锁" or "锁定", CH.lock[f.key] and "sel" or nil, hits, "lock", i)
    end
    y = y + rowH
  end
  y = y + 4 * u
  sep(x0, y, x1 - x0); y = y + 6 * u
  local tw = (x1 - x0 - 4 * u) / 2
  for i, tg in ipairs(TOGGLES) do
    local col = (i - 1) % 2
    local r = { x0 + col * (tw + 4 * u), y, tw, L + 8 * u }
    button(r, tg.cn .. (CH[tg.key] and "：开" or "：关"), CH[tg.key] and "on" or nil, hits, "toggle", tg.key)
    if col == 1 then y = y + L + 10 * u end
  end
  y = y + 4 * u
  text("点击输入框→输入数字→回车", x0, y, COL.dim)
  y = y + L + 2 * u
  if CH.msg then text(CH.msg, x0, y, COL.gold) else text("锁定：数值一直保持不变", x0, y, COL.dim) end
end

local function apply_field(i)
  local f = VALUES[i]
  local n = tonumber(CH.buf)
  if not n or n ~= n or n == math.huge then ch_msg("请输入数字"); return end
  if n < 0 then ch_msg("不能为负数"); return end
  if not f.decimal then n = math.floor(n + 0.5) end
  if n > 1e9 then n = 1e9 end
  if not f.nolock and not in_run() then ch_msg("请先进入一局"); return end
  f.set(n)
  if CH.lock[f.key] then CH.lockval[f.key] = n end
  info("功能面板：" .. f.cn .. " = " .. fmt_val(n, f.decimal))
  ch_msg(f.cn .. " 已设为 " .. fmt_val(n, f.decimal))
  CH.focus = nil; CH.buf = ""
end

local function hit_at(hits, x, y)
  for k = #hits, 1, -1 do
    if pt_in(hits[k].r, x, y) then return hits[k] end
  end
  return nil
end

function M.ch_mousepressed(x, y, b)
  if not CH.open then return false end
  if not pt_in(CH.panel, x, y) then CH.focus = nil; return false end
  if b ~= 1 then return true end
  local hh = hit_at(CH.hits, x, y)
  if not hh then CH.focus = nil; return true end
  local i = hh.extra
  if hh.id == "box" then
    CH.focus = i
    local v = VALUES[i].get()
    CH.buf = v and fmt_val(v, VALUES[i].decimal) or ""
  elseif hh.id == "apply" then
    if CH.focus ~= i then CH.focus = i; local v = VALUES[i].get(); CH.buf = v and fmt_val(v, VALUES[i].decimal) or "" end
    apply_field(i)
  elseif hh.id == "lock" then
    local f = VALUES[i]
    if CH.lock[f.key] then
      CH.lock[f.key] = false; ch_msg(f.cn .. " 已解锁")
    else
      local v = f.get()
      if v == nil then ch_msg("请先进入一局"); return true end
      CH.lock[f.key] = true; CH.lockval[f.key] = v
      ch_msg(f.cn .. " 已锁定为 " .. fmt_val(v))
    end
  elseif hh.id == "toggle" then
    local key = i
    CH[key] = not CH[key]
    if key == "free_spin" and not CH.free_spin and CH.added_credit then
      local c = tonumber(rawget(_G, "freeSpinCredits")) or 0
      if c >= 1 then rawset(_G, "freeSpinCredits", c - 1) end
      CH.added_credit = false
    end
    local cn = key
    for _, tg in ipairs(TOGGLES) do if tg.key == key then cn = tg.cn end end
    info("功能面板：" .. cn .. " = " .. tostring(CH[key]))
    ch_msg(cn .. (CH[key] and "：开" or "：关"))
  end
  return true
end

function M.ch_keypressed(key)
  if key == "f7" then
    CH.open = not CH.open; CH.focus = nil; UI.hint_t = 0
    return true
  end
  if not CH.open then return false end
  if CH.focus then
    local d = key:match("^kp(%d)$") or key:match("^(%d)$")
    if d then if #CH.buf < 12 then CH.buf = CH.buf .. d end; return true end
    if (key == "." or key == "kp.") and VALUES[CH.focus].decimal and not CH.buf:find("%.") then CH.buf = CH.buf .. "."; return true end
    if key == "backspace" then CH.buf = CH.buf:sub(1, -2); return true end
    if key == "delete" then CH.buf = ""; return true end
    if key == "return" or key == "kpenter" then apply_field(CH.focus); return true end
    if key == "escape" then CH.focus = nil; return true end
    return true
  end
  if key == "escape" then CH.open = false; return true end
  return false
end

------------------------------------------------------------------------
-- F8 面板交互
------------------------------------------------------------------------
local function shift_down()
  local ok, d = pcall(love.keyboard.isDown, "lshift", "rshift")
  return ok and d
end

local function set_row(i, v)
  local rs = row_state()
  if not rs or not rs.enabled[i] then return end
  local base_vals = (UI.drag and UI.drag.i == i and UI.drag.snap) or rs.cur
  local fb = {}
  for j, g in ipairs(rs.keys) do fb[j] = (rs.base[g] or 0) * 100 end
  apply_vals(rs, M.redistribute(base_vals, i, v, rs.enabled, fb))
end

local function set_joker(v)
  if v < 0 then v = 0 end
  if v > JOKER_MAX * 100 then v = JOKER_MAX * 100 end
  local st = CFG.symbols
  if not st or st.mode ~= "target" then
    st = { mode = "target", mult = {}, target = {} }
    CFG.symbols = st
  end
  st.joker = v / 100
  CFG.enabled = true
end

local function value_from_x(row, x, maxv)
  return (x - row.tx) / row.tw * (maxv or 100)
end

function M.ui_mousepressed(x, y, b)
  if not UI.open then return false end
  if not pt_in(UI.panel, x, y) then return false end
  if b ~= 1 then return true end
  local step = shift_down() and 1 or 0.1
  local hh = hit_at(UI.hits, x, y)
  if hh then
    local id, ex = hh.id, hh.extra
    if id == "toggle" then
      CFG.enabled = not CFG.enabled
      if M.slot_invalidate then M.slot_invalidate() end
      set_msg(CFG.enabled and "Mod 已开启" or "Mod 已关闭：全部使用原版概率")
    elseif id == "preset" then
      local ok, p = M.apply_preset(ex)
      if ok then
        CFG.enabled = true
        info("面板选择预设：" .. p.cn)
        set_msg("已应用预设：" .. p.cn .. "（老虎机与命运石，未保存）")
      end
    elseif id == "tab" then UI.tab = ex
    elseif id == "prev" then UI.stone_idx = UI.stone_idx - 1
    elseif id == "next" then UI.stone_idx = UI.stone_idx + 1
    elseif id == "reset" then
      reset_current(row_state()); set_msg("本页已恢复原版（未保存）")
    elseif id == "save" then
      local ok, e = M.save_config()
      set_msg(ok and ("已保存到 " .. CONFIG_NAME) or ("保存失败：" .. tostring(e)))
    elseif id == "minus" or id == "plus" then
      local rs = row_state()
      if rs and rs.enabled[ex] then set_row(ex, rs.cur[ex] + (id == "plus" and step or -step)) end
    elseif id == "jminus" or id == "jplus" then
      set_joker(((M.joker_override() or 0) * 100) + (id == "jplus" and step or -step))
    end
    return true
  end
  for i, r in ipairs(UI.rows or {}) do
    if r.enabled and pt_in(r.bar, x, y) then
      local rs = row_state()
      UI.drag = { i = i, snap = rs.cur }
      set_row(i, value_from_x(r, x))
      return true
    end
  end
  if UI.joker_row and pt_in(UI.joker_row.bar, x, y) then
    UI.drag = { joker = true }
    set_joker(value_from_x(UI.joker_row, x, JOKER_MAX * 100))
    return true
  end
  return true
end

function M.ui_mousemoved(x, y)
  if UI.open and UI.drag then
    if UI.drag.joker then
      if UI.joker_row then set_joker(value_from_x(UI.joker_row, x, JOKER_MAX * 100)) end
    elseif UI.rows[UI.drag.i] then
      set_row(UI.drag.i, value_from_x(UI.rows[UI.drag.i], x))
    end
    return true
  end
  return false
end

function M.ui_mousereleased(x, y, b)
  if UI.drag then
    UI.drag = nil
    local rs = row_state()
    if rs then
      local names = (rs.keys == SYMBOLS) and SYMBOL_CN or GRADE_CN
      local out = {}
      for i, g in ipairs(rs.keys) do out[g] = rs.cur[i] / 100 end
      info("面板调整 " .. rs.title .. " → " .. M.fmt_keys(out, rs.keys, names) .. (UI.tab == "symbols" and M.joker_override() and ("，小丑 " .. pct(M.joker_override())) or ""))
    end
    return true
  end
  if not UI.open then return false end
  return pt_in(UI.panel, x, y)
end

function M.ui_wheel(dx, dy)
  if not UI.open then return false end
  local ok, mx, my = pcall(love.mouse.getPosition)
  if not ok or not pt_in(UI.panel, mx, my) then return false end
  local step = (shift_down() and 1 or 0.1) * (dy > 0 and 1 or -1)
  for i, r in ipairs(UI.rows or {}) do
    if r.enabled and pt_in(r.row, mx, my) then
      local rs = row_state()
      set_row(i, rs.cur[i] + step)
      return true
    end
  end
  if UI.joker_row and pt_in(UI.joker_row.row, mx, my) then
    set_joker(((M.joker_override() or 0) * 100) + step)
  end
  return true
end

function M.ui_keypressed(key)
  if key == "f8" then
    UI.open = not UI.open; UI.drag = nil; UI.hint_t = 0
    if UI.open then pcall(M.try_stone) end
    return true
  end
  if UI.open and key == "escape" then UI.open = false; UI.drag = nil; return true end
  return false
end

function M.draw_ui()
  if UI.hint_t <= 0 and not UI.open and not CH.open then return end
  local G = love.graphics
  local okm, mx, my = pcall(love.mouse.getPosition)
  if okm then MOUSE[1], MOUSE[2] = mx, my end
  G.push("all")
  G.origin(); G.setCanvas(); G.setShader(); G.setScissor()
  G.setBlendMode("alpha")
  G.setLineStyle("rough")
  local ok1, e1 = pcall(M.draw_odds)
  local ok2, e2 = true, nil
  if CH.open then ok2, e2 = pcall(M.draw_cheat) end
  if UI.open or CH.open then pcall(M.draw_cursor) end
  G.pop()
  if not ok1 then error(e1, 0) end
  if not ok2 then error(e2, 0) end
end

local function ch_layout() return CH.panel end
M.ch_layout = function()
  local p = CH.panel or { 0, 0, 0, 0 }
  return U(), p[1], p[2], p[3], p[4]
end

function M.install_ui()
  if not (love and love.graphics and love.graphics.present and love.handlers) then
    warn("LÖVE 图形/事件接口不可用，游戏内面板未启用（配置文件仍有效）")
    return
  end
  local ui_broken = false
  local function guard(fn, ...)
    if ui_broken then return false end
    local ok, r = pcall(fn, ...)
    if not ok then
      ui_broken = true; UI.open = false
      warn("游戏内面板出错，已停用面板（概率修改不受影响）：" .. tostring(r))
      return false
    end
    return r
  end
  local last = nil
  local cheat_broken = false
  local orig_present = love.graphics.present
  love.graphics.present = function(...)
    if not ui_broken then
      local now_t = love.timer and love.timer.getTime and love.timer.getTime() or 0
      if last then
        local dt = math.min(0.25, math.max(0, now_t - last))
        if UI.hint_t > 0 then UI.hint_t = UI.hint_t - dt end
        if UI.msg_t > 0 then UI.msg_t = UI.msg_t - dt; if UI.msg_t <= 0 then UI.msg = nil end end
        if CH.msg_t > 0 then CH.msg_t = CH.msg_t - dt; if CH.msg_t <= 0 then CH.msg = nil end end
      end
      last = now_t
      guard(M.draw_ui)
    end
    pcall(M.ensure_joker_hooks)
    if not cheat_broken then
      local okc, ec = pcall(M.cheat_tick)
      if not okc then cheat_broken = true; warn("功能面板逻辑出错，已停用（概率修改不受影响）：" .. tostring(ec)) end
    end
    return orig_present(...)
  end
  local H = love.handlers
  local function wrap(name, fn)
    local orig = H[name]
    if type(orig) ~= "function" then return end
    H[name] = function(...)
      if guard(fn, ...) then return end
      return orig(...)
    end
  end
  local function in_ch(x, y)
    if not CH.open then return false end
    local _, px, py, pw, ph = M.ch_layout()
    return pt_in({ px, py, pw, ph }, x, y)
  end
  wrap("keypressed", function(key) return M.ch_keypressed(key) or M.ui_keypressed(key) end)
  wrap("mousepressed", function(x, y, b) return M.ch_mousepressed(x, y, b) or M.ui_mousepressed(x, y, b) end)
  wrap("mousereleased", function(x, y, b) return M.ui_mousereleased(x, y, b) or in_ch(x, y) end)
  wrap("mousemoved", M.ui_mousemoved)
  wrap("textinput", function() return CH.open and CH.focus ~= nil end)
  wrap("wheelmoved", function(dx, dy)
    if M.ui_wheel(dx, dy) then return true end
    local ok, mx, my = pcall(love.mouse.getPosition)
    return ok and in_ch(mx, my)
  end)
  info("游戏内面板已启用：F8 = 稀有度/符号概率，F7 = 功能面板")
  if rawget(_G, "__ODDSMOD_EXPOSE") then rawset(_G, "__ODDSMOD_UI", UI); rawset(_G, "__ODDSMOD_CH", CH) end
end

local function show_popup()
  if not CFG.show_error_popup or #popup_msgs == 0 then return end
  local msg = "Slotbound 概率 Mod 配置有问题，相关部分已改用原版概率：\n\n" ..
    table.concat(popup_msgs, "\n") ..
    "\n\n请修改游戏目录下的 " .. CONFIG_NAME .. " 后重启游戏。\n详细信息见 " .. LOG_NAME
  pcall(function()
    if love and love.window and love.window.showMessageBox then
      love.window.showMessageBox("Slotbound 概率 Mod", msg, "warning")
    end
  end)
end

function M.init()
  -- 日志与配置位置
  local dirs = find_base_dirs()
  local cfg_path = nil
  for _, d in ipairs(dirs) do
    local p = d .. "/" .. CONFIG_NAME
    if file_exists(p) then cfg_path = p; base_dir = d; break end
  end
  local log_dir = base_dir
  if not log_dir then
    for _, d in ipairs(dirs) do
      local f = io.open(d .. "/" .. LOG_NAME, "w")
      if f then f:close(); log_dir = d; break end
    end
  end
  if log_dir then
    log_file = io.open(log_dir .. "/" .. LOG_NAME, "w")
    if log_file then
      for _, l in ipairs(log_lines) do log_file:write(l, "\n") end
      log_lines = {}
    end
  end

  info("Slotbound 概率 Mod v" .. MOD_VERSION .. " 已加载，作者 " .. MOD_AUTHOR .. "（适配游戏版本 " .. GAME_VERSION_TESTED .. "）")
  info("候选目录：" .. table.concat(dirs, " | "))

  if not cfg_path then
    err("找不到配置文件 " .. CONFIG_NAME .. "（应放在游戏 exe 同目录）。Mod 不修改任何概率。")
    CFG.enabled = false
  else
    info("配置文件：" .. cfg_path)
    M.cfg_path = cfg_path
    local f = io.open(cfg_path, "rb")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    M.load_config_text(text)
  end
  info("总开关 enabled=" .. tostring(CFG.enabled) .. "，respect_unlocks=" .. tostring(CFG.respect_unlocks))
  info("局内老虎机设置：" .. describe(CFG.enabled and CFG.slot or nil))
  info("命运石默认设置：" .. describe(CFG.enabled and CFG.stone_default or nil))
  for k, s in pairs(CFG.stone) do
    info("命运石单独设置 " .. (STONE_CN[k] or k) .. "：" .. (s._invalid and "配置无效→原版" or describe(s)))
  end

  -- 局内老虎机
  local okc, C = pcall(require, "src.data.constants")
  if okc and type(C) == "table" and type(C.unitGrades) == "table" and type(C.unitGrades.probabilities) == "table" then
    if M.install_slot_proxy(C.unitGrades.probabilities, "局内老虎机") then
      info("已挂接局内老虎机稀有度表 (constants.unitGrades.probabilities)")
      -- 触发一次计算并打印
      local _ = C.unitGrades.probabilities.normal
    end
  else
    warn("找不到 constants.unitGrades.probabilities（游戏可能已更新），局内老虎机概率未修改")
  end

  -- 符号概率
  if okc and type(C) == "table" and type(C.slot) == "table" then
    if M.install_symbol_proxy(C.slot) then info("已挂接符号概率表 (constants.slot.symbolWeights)") end
  end
  pcall(M.ensure_joker_hooks)
  if M.symbol_settings() then local _ = C.slot.symbolWeights end
  info("符号概率设置：" .. (M.symbol_settings() and "目标概率" or "原版") .. (M.joker_override() and ("，小丑 " .. pct(M.joker_override())) or ""))

  -- 命运石：模块可能稍后才加载，挂接 require（另外老虎机概率表每次被读取时也会检查一次）
  local try_stone = M.try_stone
  if not try_stone() then
    local prev = require
    local done = false
    require = function(name, ...)
      local a, b = prev(name, ...)
      if not done and name == "src.game.stone" then done = try_stone() end
      return a, b
    end
    info("命运石模块尚未加载，将在其加载时自动挂接")
  end

  if not M.cfg_path and base_dir == nil and dirs[1] then M.cfg_path = dirs[1] .. "/" .. CONFIG_NAME end
  show_popup()
  local oku, eu = pcall(M.install_ui)
  if not oku then warn("游戏内设置面板安装失败（不影响概率修改）：" .. tostring(eu)) end
end

------------------------------------------------------------------------
-- 入口
------------------------------------------------------------------------
if rawget(_G, "__ODDSMOD_TEST") then
  return M
end

local orig_bytes = ...
local loader = loadstring or load
local chunk = assert(loader(orig_bytes, "=src/game/luck.lua"))
local results = { chunk(select(2, ...)) }

local ok, e = pcall(M.init)
if not ok then
  pcall(log, "错误", "Mod 初始化失败，游戏将按原版运行：" .. tostring(e))
end

local unpack_ = unpack or table.unpack
return unpack_(results)
