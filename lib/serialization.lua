local serialization = {}

-- Same output as OpenOS's serialization, except floats that 14 digits do not read back exactly
-- (they get up to 17). Tokens go in one list, which is joined into a chunk every 256 tokens; the
-- chunks are joined in pairs at the end. Runs of plain integers or plain strings in an array are
-- joined by table.concat straight from the table. So serializing needs about twice its output in
-- free memory, and no large table.concat (whose buffer cannot collect garbage to grow).
local type, tostring, tonumber, getmetatable, pairs, next, error, pcall, load, checkArg =
      type, tostring, tonumber, getmetatable, pairs, next, error, pcall, load, checkArg
local find, format, gsub, rep, sub = string.find, string.format, string.gsub, string.rep, string.sub
local concat, sort = table.concat, table.sort
local huge, ceil = math.huge, math.ceil
local ESCAPED = '[%c"\\]' -- what %q changes: without these a string is itself between quotes
local ID = "^[%a_][%w_]*$"
local RUN = 64 -- most array values joined at once
local STOP = {} -- raised when pretty output reaches its last line

local kw = {["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true,
            ["elseif"]=true, ["end"]=true, ["false"]=true, ["for"]=true,
            ["function"]=true, ["goto"]=true, ["if"]=true, ["in"]=true,
            ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
            ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
            ["until"]=true, ["while"]=true}

-- delay loaded tables fail to deserialize cross [C] boundaries (such as when having to read files that cause yields)
local local_pairs = function(tbl)
  local mt = getmetatable(tbl)
  return (mt and mt.__pairs or pairs)(tbl)
end

local function number(v)
  if v ~= v then
    return "0/0"
  elseif v == huge then
    return "math.huge"
  elseif v == -huge then
    return "-math.huge"
  end
  local s = tostring(v)
  if (v % 1 ~= 0 or v >= 1e14 or v <= -1e14) and tonumber(s) ~= v then
    for digits = 15, 17 do
      s = format("%." .. digits .. "g", v)
      if tonumber(s) == v then break end
    end
    if not find(s, "[.e]") then s = s .. ".0" end
  end
  return s
end

-- Each put adds a value's tokens to out after index n and returns the new last index. ctx holds
-- the call's options, its chunks (1..ctx.c) and the tables being written (a cycle).

-- A token that may hold newlines, in pretty output with a line limit: stops at the last line's.
local function lines(tok, out, n, ctx)
  local at = find(tok, "\n", 1, true)
  while at do
    ctx.lines = ctx.lines + 1
    if ctx.lines >= ctx.maxLines then
      out[n] = sub(tok, 1, at)
      ctx.n = n
      error(STOP, 0)
    end
    at = find(tok, "\n", at + 1, true)
  end
end

local putTable

local function put(v, depth, out, n, ctx)
  local t = type(v)
  if t == "string" then
    if find(v, ESCAPED) then
      n = n + 1; out[n] = gsub(format("%q", v), "\\\n", "\\n")
    else
      out[n + 1], out[n + 2], out[n + 3] = '"', v, '"'
      n = n + 3
    end
  elseif t == "number" then
    n = n + 1; out[n] = number(v)
  elseif t == "nil" or t == "boolean" or
      ctx.pretty and (t ~= "table" or (getmetatable(v) or {}).__tostring) then
    n = n + 1; out[n] = tostring(v)
    if ctx.maxLines then lines(out[n], out, n, ctx) end
  elseif t == "table" then
    n = putTable(v, depth, out, n, ctx)
  else
    error("unsupported type: " .. t)
  end
  return n
end

function putTable(t, depth, out, n, ctx)
  local pretty = ctx.pretty
  if ctx[t] then
    if not pretty then
      error("tables with cycles are not supported")
    end
    n = n + 1; out[n] = "recursion"
    return n
  end
  ctx[t] = true
  local f, s, c = local_pairs(t)
  -- Values straight from t (no __pairs, not pretty): runs of them can be joined from t.
  local plain = f == next and not pretty
  if pretty then
    local ks, sks, oks = {}, {}, {}
    for k in f, s, c do
      local tk = type(k)
      local list = tk == "number" and ks or tk == "string" and sks or oks
      list[#list + 1] = k
    end
    sort(ks)
    sort(sks)
    local nk = #ks
    for j = 1, #sks do ks[nk + j] = sks[j] end
    nk = #ks
    for j = 1, #oks do ks[nk + j] = oks[j] end
    local j = 0
    f, s, c = function()
      j = j + 1
      local k = ks[j]
      if k ~= nil then
        return k, t[k]
      end
    end, nil, nil
  end
  local sep = pretty and ",\n" .. rep(" ", depth) or ","
  local maxLines, names = ctx.maxLines, ctx.names
  local i, first, run, runKind = 1, true, nil, nil
  n = n + 1; out[n] = "{"
  for k, v in f, s, c do
    -- The next array value, a plain integer or a short plain string: joins the run (kind 1 or 2).
    local kind
    if plain and k == i then
      local tv = type(v)
      if tv == "number" then
        if v % 1 == 0 and v < 1e14 and v > -1e14 then kind = 1 end
      elseif tv == "string" and #v <= 64 and not find(v, ESCAPED) then
        kind = 2
      end
    end
    if kind and kind == runKind and i - run < RUN then
      i = i + 1
    else
      if run then
        if not first then n = n + 1; out[n] = sep end
        first = false
        if runKind == 1 then
          n = n + 1; out[n] = concat(t, ",", run, i - 1)
        else
          out[n + 1], out[n + 2], out[n + 3] = '"', concat(t, '","', run, i - 1), '"'
          n = n + 3
        end
        run, runKind = nil, nil
      end
      if kind then
        run, runKind = i, kind
        i = i + 1
      else
        if first then
          first = false
        else
          n = n + 1; out[n] = sep
          if maxLines then lines(sep, out, n, ctx) end
        end
        if k == i then
          i = i + 1
        else
          local name = false -- k's "k=" token, if k is a name
          if type(k) == "string" then
            name = names[k]
            if name == nil then
              name = not kw[k] and find(k, ID) and k .. "=" or false
              names[k] = name
            end
          end
          if name then
            n = n + 1; out[n] = name
          else
            n = n + 1; out[n] = "["
            n = put(k, depth + 1, out, n, ctx)
            out[n + 1], out[n + 2] = "]", "="
            n = n + 2
          end
        end
        local tv = type(v) -- the common values here, the rest in put
        if tv == "string" and not find(v, ESCAPED) then
          out[n + 1], out[n + 2], out[n + 3] = '"', v, '"'
          n = n + 3
        elseif tv == "number" then
          n = n + 1; out[n] = number(v)
        elseif tv == "boolean" then
          n = n + 1; out[n] = v and "true" or "false"
        else
          n = put(v, depth + 1, out, n, ctx)
        end
      end
    end
    if n >= 256 then
      local cn = ctx.c + 1
      ctx.c = cn
      ctx[cn] = concat(out, "", 1, n)
      n = 0
    end
  end
  if run then
    if not first then n = n + 1; out[n] = sep end
    if runKind == 1 then
      n = n + 1; out[n] = concat(t, ",", run, i - 1)
    else
      out[n + 1], out[n + 2], out[n + 3] = '"', concat(t, '","', run, i - 1), '"'
      n = n + 3
    end
  end
  ctx[t] = nil -- allow writing same table more than once
  n = n + 1; out[n] = "}"
  return n
end

-- Important: pretty formatting will allow presenting non-serializable values
-- but may generate output that cannot be unserialized back.
function serialization.serialize(value, pretty)
  local ctx = {pretty = pretty, lines = 0, c = 0, names = {}}
  if pretty then
    local limit = type(pretty) == "number" and pretty or 10
    if not (limit > 0) then
      return "..."
    elseif limit ~= huge then
      ctx.maxLines = ceil(limit) -- the output is cut after this many lines, so it stops there
    end
  end
  local out = {}
  local ok, n = pcall(put, value, 1, out, 0, ctx)
  if not ok then
    if n ~= STOP then
      error(n, 0)
    end
    n = ctx.n
  end
  local c = ctx.c + 1
  ctx[c] = concat(out, "", 1, n)
  out = nil
  -- In pairs: a .. b is made at its size, where one concat grows a buffer by doubling.
  while c > 1 do
    local m = 0
    for j = 1, c, 2 do
      local a, b = ctx[j], ctx[j + 1]
      ctx[j], ctx[j + 1] = nil, nil
      m = m + 1
      ctx[m] = b and a .. b or a
    end
    c = m
  end
  return ok and ctx[1] or ctx[1] .. "..."
end

function serialization.unserialize(data)
  checkArg(1, data, "string")
  local result, reason = load("return " .. data, "=data", nil, {math={huge=math.huge}})
  if not result then
    return nil, reason
  end
  local ok, output = pcall(result)
  if not ok then
    return nil, output
  end
  return output
end

return serialization
