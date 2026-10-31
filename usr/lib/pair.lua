-- pair: trust another computer by swapping wake keys and keys, saved in hosts.
-- Finding the other side is disco's job; pair only runs the handshake.
local event = require("event")
local computer = require("computer")
local component = require("component")
local serialization = require("serialization")
local hosts = require("hosts")
local uuid = require("uuid")
local disco = require("disco")

local pair = {}

local function hostname()
    local f = io.open("/etc/hostname")
    if not f then return nil end
    local name = f:read("*a")
    f:close()
    name = name and name:match("^%s*(.-)%s*$")
    return name ~= "" and name or nil
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Defaults shared by both sides: name, own secret, and the localhost hosts entry.
local function prepare(opts)
    local log = opts.log or function() end
    local name = opts.name or hostname()
    if not name then return nil, "hostname required (argument or /etc/hostname)" end
    local localHost = hosts.localhost()
    local secret = opts.secret or (localHost and localHost:getWakeKey()) or uuid.next():sub(-12)
    if not localHost then
        hosts.addHost(component.modem.address, computer.address(), name, secret, opts.keys)
        log("✅ Registered localhost (" .. name .. " = " .. computer.address() .. ")")
    end
    return {name = name, secret = secret, keys = opts.keys or {}, log = log}
end

-- Wait until done() is true, the deadline passes or the user interrupts.
local function waitFor(done, timeout)
    local interrupted = false
    local onInterrupt = function() interrupted = true return false end
    event.listen("interrupted", onInterrupt)
    local deadline = computer.uptime() + (timeout or math.huge)
    local ok, err = pcall(function()
        while not done() and not interrupted and computer.uptime() < deadline do os.sleep(0.1) end
    end)
    event.ignore("interrupted", onInterrupt)
    if not ok then error(err, 0) end
    return interrupted
end

-- Pairing servers offering this port, as disco entries.
function pair.servers(port, timeout)
    local out = {}
    for _, e in ipairs(disco.find("pair", timeout)) do
        if e.services.pair == port then out[#out + 1] = e end
    end
    return out
end

-- Offer pairing on port until one client pairs. opts: name, secret, clientSecret, client,
-- keys, overwrite, timeout, log. Returns the client's name, or nil and a reason.
function pair.serve(port, opts)
    opts = opts or {}
    local me, err = prepare(opts)
    if not me then return nil, err end
    local log = me.log
    local opened = {}
    for address in component.list("modem") do
        if not component.invoke(address, "isOpen", port) then
            component.invoke(address, "open", port)
            opened[address] = true
        end
    end
    local wasAnnouncing = disco.running()
    if wasAnnouncing then disco.offer("pair", port) else
        disco.start({name = me.name, services = {pair = port}})
    end

    local paired, pairedAt, gotKeys, failure
    local function onMessage(_, via, sender, recvPort, _, protocol, arg1, arg2, arg3, arg4)
        if recvPort ~= port then return end
        local modem = component.proxy(via)
        if protocol == "PAIR_REQUEST" and arg1 and arg2 and arg3 and not paired then
            if arg1 ~= me.secret then
                log("❌ Auth failed from " .. sender .. ": wrong secret.")
                modem.send(sender, port, "PAIR_REJECT", "wrong_secret")
                return
            end
            if opts.client and arg2 ~= opts.client then
                log("❌ Client name mismatch: got '" .. arg2 .. "', expected '" .. opts.client .. "'")
                modem.send(sender, port, "PAIR_REJECT", "wrong_client_name")
                return
            end
            log("✅ Authenticated client: " .. arg2 .. " (" .. sender .. ")")
            if next(me.keys) then
                modem.send(sender, port, "SERVER_KEYS", serialization.serialize(me.keys))
                log("📤 Sent " .. count(me.keys) .. " keys to client.")
            end
            -- The client's own wake key, unless the operator gave one for it.
            local saved, reason = hosts.addHost(sender, arg3, arg2, opts.clientSecret or arg4, nil, opts.overwrite, via)
            if saved then log("💾 Saved client host: " .. arg2) else
                log("⚠️  Failed to save client: " .. tostring(reason))
                failure = reason
            end
            modem.send(sender, port, "PAIR_SUCCESS", me.name, computer.address(), me.secret, opts.clientSecret)
            modem.setWakeMessage(me.secret, true)  -- the client may now wake us through this card
            log("✅ Pairing completed with " .. arg2)
            paired, pairedAt = arg2, computer.uptime()
        elseif protocol == "CLIENT_KEYS" and arg1 and paired then
            local ok, clientKeys = pcall(serialization.unserialize, arg1)
            local host = hosts.getHost(sender)
            if ok and type(clientKeys) == "table" and host then
                log("📥 Received " .. count(clientKeys) .. " keys from client.")
                local merged = host:getKeys()
                for k, v in pairs(clientKeys) do merged[k] = v end
                hosts.addHost(sender, host:getCID(), host:getName(), host:getWakeKey(), merged, true, host:getVia())
                log("💾 Updated client keys.")
            else
                log("⚠️ Received invalid keys from client.")
            end
            gotKeys = true
        end
    end

    event.listen("modem_message", onMessage)
    log("📡 Offering pairing as '" .. me.name .. "' on port " .. port)
    local ok, interrupted = pcall(waitFor, function()
        -- After success, give the client a moment to send its keys.
        return paired and (gotKeys or computer.uptime() > pairedAt + 1)
    end, opts.timeout)
    event.ignore("modem_message", onMessage)
    disco.withdraw("pair")
    if not wasAnnouncing then disco.stop() end
    for address in pairs(opened) do pcall(component.invoke, address, "close", port) end
    if not ok then error(interrupted, 0) end
    if paired and not failure then return paired end
    return nil, failure or (interrupted and "interrupted" or "timed out")
end

-- Pair with a server found by disco (or any {address, name, via}). opts: name, secret,
-- serverSecret, keys, overwrite, timeout, log. Returns true, or nil and a reason.
function pair.with(server, port, opts)
    opts = opts or {}
    local me, err = prepare(opts)
    if not me then return nil, err end
    local log = me.log
    local modem = component.proxy(server.via or component.modem.address)
    local wasOpen = modem.isOpen(port)
    modem.open(port)

    local done, failure, serverKeys
    local function onMessage(_, via, sender, recvPort, _, protocol, data, serverCID, serverSecret)
        -- Networks with loops deliver duplicates; only the first answer counts.
        if done or sender ~= server.address or recvPort ~= port or via ~= modem.address then return end
        if protocol == "SERVER_KEYS" and data then
            local ok, keys = pcall(serialization.unserialize, data)
            if ok and type(keys) == "table" then
                serverKeys = keys
                log("📥 Received " .. count(keys) .. " keys from server.")
            else
                log("⚠️ Received invalid keys from server.")
            end
        elseif protocol == "PAIR_SUCCESS" and data and serverCID then
            done = true
            log("✅ Server confirmed pairing: " .. data)
            if opts.serverSecret and serverSecret ~= opts.serverSecret then
                failure = "server secret mismatch"
                log("❌ Server secret mismatch")
                return
            end
            local saved, reason = hosts.addHost(server.address, serverCID, server.name or data,
                serverSecret, serverKeys, opts.overwrite, modem.address)
            if saved then log("💾 Saved server host: " .. (server.name or data)) else
                failure = reason
                log("⚠️  Failed to save server: " .. tostring(reason))
            end
            modem.setWakeMessage(me.secret, true)  -- the server may now wake us through this card
            if next(me.keys) then
                log("📤 Sending " .. count(me.keys) .. " keys to server.")
                modem.send(server.address, port, "CLIENT_KEYS", serialization.serialize(me.keys))
            end
        elseif protocol == "PAIR_REJECT" then
            done, failure = true, "rejected: " .. tostring(data or "no reason given")
            log("❌ Server rejected pairing: " .. tostring(data or "no reason given"))
        end
    end

    event.listen("modem_message", onMessage)
    log("🤝 Sending pairing request to " .. tostring(server.name or server.address) .. "...")
    modem.send(server.address, port, "PAIR_REQUEST", opts.serverSecret, me.name, computer.address(), me.secret)
    local ok, interrupted = pcall(waitFor, function() return done end, opts.timeout or 10)
    event.ignore("modem_message", onMessage)
    if not wasOpen then modem.close(port) end
    if not ok then error(interrupted, 0) end
    if not done then return nil, interrupted and "interrupted" or "timed out" end
    if failure then return nil, failure end
    return true
end

return pair
