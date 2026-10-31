local shell = require("shell")
local event = require("event")
local pair = require("pair")
local args, options = shell.parse(...)

if #args == 0 or options.h or options.help then
    print([[
Usage:
  pair server <port> [hostname] --secret=<str> [--client-secret=<str>] [--client=<name>] [--keys=k1,v1,k2,v2] [--overwrite]
  pair client <port> [hostname] --secret=<str> [--server-secret=<str>] [--server=<name>] [--keys=k1,v1,k2,v2] [--overwrite]
Server mode: offers pairing through disco. Waits for client auth.
Client mode: if --server and --server-secret given, auto-pairs. Otherwise, scans and lets user choose.
]])
    os.exit(0)
end

local function parseKeys(text)
    local keys, parts = {}, {}
    for part in string.gmatch(text or "", "[^,]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1, 2 do keys[parts[i]] = parts[i + 1] end
    return keys
end

local mode, port = args[1], tonumber(args[2])
if not port then
    io.stderr:write("Error: port required.\n")
    os.exit(1)
end
if not require("component").isAvailable("modem") then
    io.stderr:write("Error: No modem found.\n")
    os.exit(1)
end

local opts = {
    name = args[3] ~= "" and args[3] or nil,
    secret = options.secret,
    keys = parseKeys(options.keys),
    overwrite = options.overwrite,
    log = print
}

local function finish(ok, err)
    if not ok then
        io.stderr:write("❌ " .. tostring(err) .. "\n")
        os.exit(1)
    end
    print("🎉 Pairing complete!")
    os.exit(0)
end

if mode == "server" then
    opts.clientSecret = options["client-secret"] or options.clientSecret
    opts.client = options.client
    finish(pair.serve(port, opts))
elseif mode ~= "client" then
    io.stderr:write("Error: mode must be 'server' or 'client'.\n")
    os.exit(1)
end

opts.serverSecret = options["server-secret"] or options.serverSecret
local wanted = options.server
local interrupted = false
local onInterrupt = function() interrupted = true return false end
event.listen("interrupted", onInterrupt)
local function scan(timeout)
    local servers = pair.servers(port, timeout)
    if interrupted then
        event.ignore("interrupted", onInterrupt)
        io.stderr:write("Interrupted.\n")
        os.exit(1)
    end
    return servers
end

print("📡 Scanning for servers on port " .. port .. "...")
if wanted and opts.serverSecret then
    print("🔁 Auto-pairing to server: " .. wanted)
    while true do
        for _, s in ipairs(scan(1)) do
            if s.name == wanted then
                event.ignore("interrupted", onInterrupt)
                print("🎯 Found " .. s.name .. " at " .. s.address .. ", dist: " .. tostring(s.distance))
                finish(pair.with(s, port, opts))
            end
        end
    end
end

local servers = {}
while #servers == 0 do servers = scan(2) end
event.ignore("interrupted", onInterrupt)
for i, s in ipairs(servers) do
    print(string.format("📶 [%d] %s (addr: %s, comp: %s, dist: %s)", i, s.name, s.address, s.cid, tostring(s.distance)))
end
print("\nSelect server by number (Ctrl+C to cancel):")
while true do
    io.write("> ")
    local line = io.read()
    if not line then os.exit(1) end
    local s = servers[tonumber(line)]
    if s then
        io.write("Enter wake password for " .. s.name .. ": ")
        opts.serverSecret = io.read()
        if opts.serverSecret and #opts.serverSecret > 0 then finish(pair.with(s, port, opts)) end
        print("Password required.")
    else
        print("Invalid selection.")
    end
end
