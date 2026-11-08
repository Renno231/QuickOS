-- disco: name and service discovery over modem broadcasts.
-- Answers say who is reachable right now; trust and secrets stay in hosts/pair.
local event = require("event")
local computer = require("computer")
local component = require("component")

local disco = {port = 5353, ttl = 120}

local PROTO = "disco1"
local cache = {}     -- cid -> entry
local pending = {}   -- qid -> {results = {cid -> entry}}
local announced      -- {name, services, ttl, timer} while announcing
local listening, opened, nextQuery = false, {}, 0

local function hostname()
    local f = io.open("/etc/hostname")
    if not f then return nil end
    local name = f:read("*l")
    f:close()
    name = name and name:match("^%s*(.-)%s*$")
    return name ~= "" and name or nil
end

-- Services travel as "name=value,name=value"; values that look numeric come back as numbers.
local function encode(services)
    local out = {}
    for k, v in pairs(services) do out[#out + 1] = k .. "=" .. tostring(v) end
    table.sort(out)
    return table.concat(out, ",")
end

local function decode(text)
    local services = {}
    for k, v in tostring(text or ""):gmatch("([^,=]+)=([^,]*)") do
        services[k] = tonumber(v) or v
    end
    return services
end

local function broadcast(...)
    for address in component.list("modem") do
        pcall(component.invoke, address, "broadcast", disco.port, PROTO, ...)
    end
end

local function matches(kind, value, name, services)
    if kind == "name" then return name == value end
    if kind == "service" then return services[value] ~= nil end
    return true
end

local function remember(qid, sender, via, distance, name, cid, services, ttl)
    if type(name) ~= "string" or type(cid) ~= "string" or cid == computer.address() then return end
    local now = computer.uptime()
    ttl = tonumber(ttl) or disco.ttl
    local entry = {
        name = name, cid = cid, address = sender, via = via, distance = distance,
        services = decode(services), seen = now, ttl = ttl, expires = now + ttl
    }
    cache[cid] = entry
    local query = qid and pending[qid]
    if query then query.results[cid] = entry end
end

local function onMessage(_, via, sender, port, distance, proto, kind, ...)
    if port ~= disco.port or proto ~= PROTO then return end
    if kind == "Q" then
        local qid, qkind, qvalue = ...
        if announced and matches(qkind, qvalue, announced.name, announced.services) then
            pcall(component.invoke, via, "send", sender, disco.port, PROTO, "R", qid,
                announced.name, computer.address(), encode(announced.services), announced.ttl)
        end
    elseif kind == "A" or kind == "R" then
        remember((...), sender, via, distance, select(2, ...))
    elseif kind == "B" then
        local cid = ...
        if cache[cid] and cache[cid].address == sender then cache[cid] = nil end
    end
end

local function listen()
    if listening then return end
    for address in component.list("modem") do
        if not component.invoke(address, "isOpen", disco.port) then
            component.invoke(address, "open", disco.port)
            opened[address] = true
        end
    end
    event.listen("modem_message", onMessage)
    listening = true
end

-- Stop listening once nothing is announced or waiting on answers.
local function release()
    if not listening or announced or next(pending) then return end
    event.ignore("modem_message", onMessage)
    for address in pairs(opened) do pcall(component.invoke, address, "close", disco.port) end
    listening, opened = false, {}
end

local function announce()
    if announced then
        broadcast("A", "", announced.name, computer.address(), encode(announced.services), announced.ttl)
    end
end

local function ask(kind, value)
    listen()
    nextQuery = nextQuery + 1
    local qid = tostring(nextQuery)
    local q = {results = {}}
    pending[qid] = q
    broadcast("Q", qid, kind, value or "")
    return qid, q
end

local function query(kind, value, timeout, first)
    local qid, q = ask(kind, value)
    local deadline = computer.uptime() + (timeout or 1)
    local ok, err = pcall(function()
        repeat os.sleep(0.05) until computer.uptime() >= deadline or (first and next(q.results))
    end)
    pending[qid] = nil
    release()
    if not ok then error(err, 0) end
    return q.results
end

-- Start (or update) announcing this computer. opts: name, services {name = value}, ttl seconds.
function disco.start(opts)
    opts = opts or {}
    announced = announced or {services = {}}
    announced.name = opts.name or announced.name or hostname() or computer.address():sub(1, 8)
    announced.ttl = opts.ttl or announced.ttl or disco.ttl
    for k, v in pairs(opts.services or {}) do announced.services[k] = v end
    listen()
    if announced.timer then event.cancel(announced.timer) end
    announced.timer = event.timer(announced.ttl / 2, announce, math.huge)
    announce()
    return true
end

function disco.stop()
    if not announced then return false end
    event.cancel(announced.timer)
    broadcast("B", computer.address())
    announced = nil
    release()
    return true
end

function disco.running()
    return announced ~= nil
end

-- What this computer is announcing, or nil.
function disco.status()
    if not announced then return nil end
    local services = {}
    for k, v in pairs(announced.services) do services[k] = v end
    return {name = announced.name, cid = computer.address(), services = services, ttl = announced.ttl}
end

function disco.offer(service, value)
    return disco.start({services = {[service] = value == nil and true or value}})
end

function disco.withdraw(service)
    if not announced then return false end
    announced.services[service] = nil
    announce()
    return true
end

-- First live host with this name: from the cache, else by asking the network.
function disco.resolve(name, timeout)
    local now = computer.uptime()
    for _, e in pairs(cache) do
        if e.name == name and e.expires > now then return e end
    end
    local _, e = next(query("name", name, timeout or 2, true))
    if e then return e end
    return nil, "not found"
end

-- Every host that answers within timeout, optionally only those offering service.
local function sorted(results)
    local list = {}
    for _, e in pairs(results) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function disco.find(service, timeout)
    return sorted(query(service and "service" or "all", service, timeout or 1))
end

-- disco.find without waiting: returns at once and calls callback(list) after timeout seconds.
function disco.findAsync(service, timeout, callback)
    local qid, q = ask(service and "service" or "all", service)
    event.timer(timeout or 1, function()
        pending[qid] = nil
        release()
        callback(sorted(q.results))
    end)
end

-- Hosts heard recently (announcements and answers) that have not expired.
function disco.peers()
    local now, list = computer.uptime(), {}
    for cid, e in pairs(cache) do
        if e.expires > now then list[#list + 1] = e else cache[cid] = nil end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

return disco
