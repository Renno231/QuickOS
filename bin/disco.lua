local shell = require("shell")
local disco = require("disco")
local args, options = shell.parse(...)

local function services(text)
    local out = {}
    for k, v in tostring(text or ""):gmatch("([^,=]+)=([^,]*)") do out[k] = tonumber(v) or v end
    return out
end

local function describe(services)
    local out = {}
    for k, v in pairs(services) do out[#out + 1] = k .. "=" .. tostring(v) end
    table.sort(out)
    return table.concat(out, ",")
end

local function show(e)
    print(string.format("%-16s %s  dist=%-5s %s", e.name, e.address, tostring(e.distance), describe(e.services)))
end

local timeout = tonumber(options.timeout)
local command = args[1]

if command == "start" then
    disco.start({name = args[2], services = services(options.services), ttl = tonumber(options.ttl)})
    local s = disco.status()
    print("announcing " .. s.name .. " " .. describe(s.services))
elseif command == "stop" then
    if not disco.stop() then io.stderr:write("not announcing\n"); os.exit(1) end
elseif command == "offer" and args[2] then
    disco.offer(args[2], args[3] and (tonumber(args[3]) or args[3]))
elseif command == "withdraw" and args[2] then
    if not disco.withdraw(args[2]) then io.stderr:write("not announcing\n"); os.exit(1) end
elseif command == "status" then
    local s = disco.status()
    if not s then print("not announcing"); os.exit(1) end
    print("announcing " .. s.name .. " ttl=" .. s.ttl .. " " .. describe(s.services))
elseif command == "find" then
    local list = disco.find(args[2], timeout)
    for _, e in ipairs(list) do show(e) end
    if #list == 0 then io.stderr:write("no hosts found\n"); os.exit(1) end
elseif command == "resolve" and args[2] then
    local e, err = disco.resolve(args[2], timeout)
    if not e then io.stderr:write(err .. "\n"); os.exit(1) end
    show(e)
elseif command == "list" then
    for _, e in ipairs(disco.peers()) do show(e) end
else
    print([[
Usage:
  disco start [name] [--services=svc=value,...] [--ttl=seconds]
  disco stop
  disco offer <service> [value]
  disco withdraw <service>
  disco status
  disco find [service] [--timeout=seconds]
  disco resolve <name> [--timeout=seconds]
  disco list
]])
    os.exit(command and 1 or 0)
end
