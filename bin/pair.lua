local shell = require("shell")
local event = require("event")
local computer = require("computer")
local component = require("component")
local hosts = require("hosts")
local uuid = require("uuid")
local serialization = require("serialization")
local args, options = shell.parse(...)

-- Helper functions
local function parseKeys(keysStr)
    if not keysStr then return true, {} end
    local keys = {}
    local parts = {}
    for part in string.gmatch(keysStr, "[^,]+") do
        table.insert(parts, part)
    end
    for i = 1, #parts, 2 do
        if parts[i+1] then
            keys[parts[i]] = parts[i+1]
        end
    end
    return true, keys
end

local function mergeKeys(existingKeys, newKeys, overwrite)
    existingKeys = existingKeys or {}
    newKeys = newKeys or {}
    local result = {}
    local conflict = false
    local conflictKey = nil

    -- Copy existing keys
    for k, v in pairs(existingKeys) do
        result[k] = v
    end

    -- Add new keys with collision detection
    for k, v in pairs(newKeys) do
        if existingKeys[k] then
            if overwrite then
                result[k] = v
            else
                conflict = true
                conflictKey = k
                break
            end
        else
            result[k] = v
        end
    end

    if conflict then
        return false, "Key collision on '" .. conflictKey .. "' and overwrite is false"
    end

    return true, result
end

-- HELP
if #args == 0 or options.h or options.help then
    print([[
Usage:
  pair server <port> <hostname> --secret=<str> [--client-secret=<str>] [--client=<name>] [--keys=k1,v1,k2,v2] [--overwrite]
  pair client <port> <hostname> --secret=<str> [--server-secret=<str>] [--server=<name>] [--keys=k1,v1,k2,v2] [--overwrite]
Server mode: broadcasts hostname every 1s. Waits for client auth.
Client mode: if --server and --secret given, auto-pairs. Otherwise, scans and lets user choose.
]])
    os.exit(0)
end

local modem = component.modem
if not modem then
    io.stderr:write("Error: No modem found.\n")
    os.exit(1)
end

-- Get computer component address for unique identification
local computerAddress = component.computer.address

local mode = args[1]
local port = tonumber(args[2])
local myName = args[3]
if not port or not myName then
    io.stderr:write("Error: port and hostname required.\n")
    os.exit(1)
end

-- Validate we can open the port
if not pcall(modem.open, port) then
    io.stderr:write("Error: Cannot open port " .. port .. ". Already in use?\n")
    os.exit(1)
end
modem.close(port) -- Will reopen when starting

-----------------------------------------------------------------------
-- SERVER MODE — Broadcast and wait for client auth
-----------------------------------------------------------------------
local running = true
local onInterrupt = function() running = false return false end
event.listen("interrupted", onInterrupt)

local localHost = hosts.localhost()
local localHostKey = (localHost and localHost:getWakeKey()) or uuid.next():sub(-12)

if mode == "server" then
    local secret = options.secret or localHostKey
    local clientSecret = options["client-secret"] or options.clientSecret
    local expectedClientName = options.client
    local overwrite = options.overwrite
    
    -- Parse server keys
    local success, serverKeys = parseKeys(options.keys)
    if not success then
        io.stderr:write("Error parsing server keys: " .. serverKeys .. "\n")
        os.exit(1)
    end
    
    if not localHost then
        hosts.addHost(modem.address, computer.address(), myName, secret, serverKeys)
        print("✅ Registered localhost (" .. myName .. " = " .. computer.address() .. ")")
    end
    
    print("📡 Server mode: Broadcasting '" .. myName .. "' on port " .. port)
    print("   Waiting for client" .. (expectedClientName and " named '" .. expectedClientName .. "'" or "") .. "...")
    modem.open(port)
    
    -- Start broadcasting our presence
    local broadcastTimer = event.timer(1, function()
        modem.broadcast(port, "TNPAIR", myName, computerAddress)
    end, math.huge)
    
    -- Listen for incoming messages
    local pairRequest = function(_, _, sender, recvPort, _, ...)
        if recvPort ~= port then return end
        local protocol, arg1, arg2, arg3 = ...
        
        if protocol == "PAIR_REQUEST" and arg1 and arg2 and arg3 then
            -- Handle authentication
            if arg1 ~= secret then
                print("❌ Auth failed from " .. sender .. ": wrong secret.", arg1,"~=", secret)
                modem.send(sender, port, "PAIR_REJECT", "wrong_secret")
                return
            end
            
            if expectedClientName and arg2 ~= expectedClientName then
                print("❌ Client name mismatch: got '" .. arg2 .. "', expected '" .. expectedClientName .. "'")
                modem.send(sender, port, "PAIR_REJECT", "wrong_client_name")
                return
            end
            
            print("✅ Authenticated client: " .. arg2 .. " (" .. sender .. ")")
            print("   Client computer address: " .. arg3)
            
            -- Send server keys (if any)
            if next(serverKeys) then
                modem.send(sender, port, "SERVER_KEYS", serialization.serialize(serverKeys))
                local count = 0
                for _ in pairs(serverKeys) do count = count + 1 end
                print("📤 Sent " .. count .. " keys to client.")
            end
            
            -- Save client host
            local success, err = pcall(hosts.addHost, sender, arg3, arg2, clientSecret, nil, overwrite)
            if success then
                print("💾 Saved client host: " .. arg2)
            else
                print("⚠️  Failed to save client: " .. err)
            end
            
            -- Send success response
            modem.send(sender, port, "PAIR_SUCCESS", myName, computerAddress, secret, clientSecret)
            print("✅ Pairing completed with " .. arg2)
            running = false
            
        elseif protocol == "CLIENT_KEYS" and arg1 then
            -- Handle client keys
            local success, clientKeys = pcall(serialization.unserialize, arg1)
            if success and clientKeys then
                local count = 0
                for _ in pairs(clientKeys) do count = count + 1 end
                print("📥 Received " .. count .. " keys from client.")
                
                -- Find client host and merge keys
                for _, h in ipairs(hosts.getAll()) do
                    if h:getAddress() == sender then
                        local mergeSuccess, mergedKeys = mergeKeys(h:getKeys(), clientKeys, true)
                        if mergeSuccess then
                            hosts.addHost(sender, h:getCID(), h:getName(), h:getWakeKey(), mergedKeys, true)
                            print("💾 Updated client keys.")
                        else
                            print("⚠️ Failed to merge keys: " .. mergedKeys)
                        end
                        break
                    end
                end
            else
                print("⚠️ Received invalid keys from client.")
            end
        end
    end
    
    event.listen("modem_message", pairRequest)
    print("👂 Listening for pairing requests...")
    
    while running do
        os.sleep(1)
    end
    
    event.cancel(broadcastTimer)
    event.ignore("modem_message", pairRequest)

-----------------------------------------------------------------------
-- CLIENT MODE — Discover and pair
-----------------------------------------------------------------------
elseif mode == "client" then
    local secret = options.secret or localHostKey
    local serverSecret = options["server-secret"] or options.serverSecret
    local serverName = options.server
    local overwrite = options.overwrite
    
    -- Parse client keys
    local success, clientKeys = parseKeys(options.keys)
    if not success then
        io.stderr:write("Error parsing client keys: " .. clientKeys .. "\n")
        os.exit(1)
    end
    
    if not localHost then
        hosts.addHost(modem.address, computer.address(), myName, secret, clientKeys)
        print("✅ Registered localhost (" .. myName .. " = " .. computer.address() .. ")")
    end
    
    print("📡 Client mode: Scanning for servers on port " .. port .. "...")
    modem.open(port)
    
    local foundServers = {} -- { addr, name, computerAddress, dist }
    
    -- Listen for broadcasts
    local broadcastListener = event.listen("modem_message", function(_, _, sender, recvPort, dist, protocol, name, serverComputerAddress)
        if recvPort == port and protocol == "TNPAIR" and name and serverComputerAddress then
            -- Avoid duplicates
            local exists = false
            for _, s in ipairs(foundServers) do
                if s.addr == sender then
                    exists = true; break
                end
            end
            if not exists then
                table.insert(foundServers, {addr = sender, name = name, computerAddress = serverComputerAddress, dist = dist})
                print(string.format("📶 [%d] %s (addr: %s, comp: %s, dist: %.1f)", 
                    #foundServers, name, sender, serverComputerAddress, dist))
            end
        end
    end)
    
    local function initiatePairing(serverAddr, serverName)
        event.cancel(broadcastListener)
        print("🤝 Sending pairing request to " .. serverName .. "...")
        modem.send(serverAddr, port, "PAIR_REQUEST", serverSecret, myName, computerAddress, secret)
        
        -- Wait for response
        local paired = false
        local serverKeys
        local timeout = computer.uptime() + 10
        
        local responseListener = event.listen("modem_message", function(_, _, sender, recvPort, _, protocol, data, serverCompAddr, serverSecretReceived)
            if sender ~= serverAddr or recvPort ~= port then return end
            
            if protocol == "SERVER_KEYS" and data then
                local success, keys = pcall(serialization.unserialize, data)
                if success and keys then
                    serverKeys = keys
                    local count = 0
                    for _ in pairs(keys) do count = count + 1 end
                    print("📥 Received " .. count .. " keys from server.")
                else
                    print("⚠️ Received invalid keys from server.")
                end
                
            elseif protocol == "PAIR_SUCCESS" and data and serverCompAddr then
                print("✅ Server confirmed pairing: " .. data)
                print("   Server computer address: " .. serverCompAddr)
                
                -- Verify server secret if provided
                if serverSecret and serverSecretReceived and serverSecret ~= serverSecretReceived then
                    print("❌ Server secret mismatch: expected '" .. serverSecret .. "', got '" .. serverSecretReceived .. "'")
                    paired = true
                    return
                elseif serverSecret and not serverSecretReceived then
                    print("❌ Server did not provide a secret for verification")
                    paired = true
                    return
                end
                
                paired = true
                -- Save server host with received keys
                local success, err = pcall(hosts.addHost, serverAddr, serverCompAddr, serverName, serverSecretReceived, serverKeys, overwrite)
                if success then
                    print("💾 Saved server host: " .. serverName)
                else
                    print("⚠️  Failed to save server: " .. err)
                end
                
                -- Send client keys to server
                if next(clientKeys) then
                    local count = 0
                    for _ in pairs(clientKeys) do count = count + 1 end
                    print("📤 Sending " .. count .. " keys to server.")
                    modem.send(serverAddr, port, "CLIENT_KEYS", serialization.serialize(clientKeys))
                end
                
            elseif protocol == "PAIR_REJECT" then
                print("❌ Server rejected pairing: " .. (data or "no reason given"))
                paired = true
            end
        end)
        
        while running and computer.uptime() < timeout and not paired do
            os.sleep(0.1)
        end
        
        event.cancel(responseListener)
        if not paired then
            print("❌ Pairing timed out.")
            os.exit(1)
        end
        
        print("🎉 Pairing complete!")
        os.exit(0)
    end
    
    -- Auto-pair if configured
    if serverName and serverSecret then
        print("🔍 Auto-pairing to server: " .. serverName)
        local target
        while not target do
            for _, s in ipairs(foundServers) do
                if s.name == serverName then
                    target = s
                    break
                end
            end
            if not target then os.sleep(0.5) end
        end
        print("🎯 Found " .. target.name .. " at " .. target.addr .. ", dist: " .. target.dist)
        initiatePairing(target.addr, target.name)
    else
        -- Manual selection
        print("\nSelect server by number (Ctrl+C to cancel):")
        while true do
            io.write("> ")
            local line = io.read()
            if not line then break end
            local idx = tonumber(line)
            if idx and foundServers[idx] then
                local s = foundServers[idx]
                io.write("Enter wake password for " .. s.name .. ": ")
                secret = io.read()
                if secret and #secret > 0 then
                    initiatePairing(s.addr, s.name)
                    break
                else
                    print("Password required.")
                end
            else
                print("Invalid selection.")
            end
        end
    end
    
    -- Keep alive for discovery
    while running do os.sleep(1) end

-----------------------------------------------------------------------
-- INVALID MODE
-----------------------------------------------------------------------
else
    io.stderr:write("Error: mode must be 'server' or 'client'.\n")
    os.exit(1)
end

event.ignore("interrupt", onInterrupt)