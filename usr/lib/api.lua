local api = {}
local tnet = require("tnet")
local computer = require("computer")
-- Active exposed endpoints (servers)
api.endpoints = {}
-- Active client proxies
api.clients = {}
-- RPC Protocol Constants
local RPC_TYPE_CALL = "rpc_call"
local RPC_TYPE_RESPONSE = "rpc_response"
local RPC_TYPE_DOC_REQUEST = "rpc_doc_req"
local RPC_TYPE_DOC_RESPONSE = "rpc_doc_res"
local RPC_TYPE_PING = "rpc_ping"

-- SERVER SIDE
local Endpoint = {}
Endpoint.__index = Endpoint
function api.expose(name, target, port, keys)
    --print("DEBUG api.expose 1 - Exposing endpoint:", name, "on port:", port)
    -- target can be string (require path) or table
    local lib = type(target) == "string" and require(target) or target
    --print("DEBUG api.expose 2 - Target library loaded")
    
    if type(lib) ~= "table" then
        --print("DEBUG api.expose 3 - Invalid target type")
        error("Target must be a table of functions or a require-able library name")
    end
    
    --print("DEBUG api.expose 4 - Creating endpoint object")
    local endpoint = setmetatable({
        name = name,
        port = port,
        lib = lib,
        accessKey = nil,
        functionKeys = {},     -- fnName → required key
        functionDocs = {},     -- fnName → description
        connections = {},      -- address → connection object
        listening = false     -- Track if endpoint is listening
    }, Endpoint)
    
    -- NEW: Automatically expose functions from the target table
    --print("DEBUG api.expose 4.5 - Auto-exposing functions")
    for fnName, fnDef in pairs(lib) do
        if type(fnDef) == "function" then
            -- Simple function - auto-expose with default documentation
            --print("DEBUG api.expose 4.6 - Auto-exposing function:", fnName)
            endpoint:exposeFunction(fnName, "Undocumented", keys and keys[fnName])
        elseif type(fnDef) == "table" and #fnDef >= 2 and type(fnDef[1]) == "function" and type(fnDef[2]) == "string" then
            -- Function with documentation - extract and expose
            --print("DEBUG api.expose 4.7 - Auto-exposing documented function:", fnName)
            endpoint:exposeFunction(fnName, fnDef[2], keys and keys[fnName])
            -- Replace the table with the actual function in the library
            lib[fnName] = fnDef[1]
        end
    end
    
    --print("DEBUG api.expose 5 - Starting listener")
    -- Start listening
    local success, err = tnet.listen(port, function(conn)
        --print("DEBUG api.expose 6 - New connection callback triggered")
        -- Authenticate
        --print("DEBUG api.expose 7 - Setting up serialization")
        conn.serial = {lib = "serialization", encode = "serialize", decode = "unserialize"}
        
        if endpoint.accessKey and conn.wake ~= endpoint.accessKey then
            --print("DEBUG api.expose 8 - Authentication failed")
            conn:close()
            return
        end
        --print("DEBUG api.expose 9 - Authentication successful")
        
        -- Track connection
        --print("DEBUG api.expose 10 - Tracking connection")
        endpoint.connections[conn.address] = conn
        
        -- Set up connection cleanup
        --print("DEBUG api.expose 11 - Setting up connection cleanup")
        local originalClose = conn.close
        conn.close = function(self, quiet)
            --print("DEBUG api.expose 12 - Connection closed")
            endpoint.connections[self.address] = nil
            originalClose(self, quiet)
        end
        
        -- Handle RPC messages
        --print("DEBUG api.expose 13 - Setting up message handler")
        conn:expect("rpc", function(c, _, msgType, ...)
            --print("DEBUG RPC handler 1 - Received RPC message")
            --print("DEBUG RPC handler 2 - Message type:", msgType)
            --print("DEBUG RPC handler 2.1 - Message type:", c, msgType, ...)
            --print("DEBUG RPC handler 3 - Additional args count:", select('#', ...))
            
            if msgType == RPC_TYPE_CALL then
                local fnName, callId, args, callKey = ...
                --print("DEBUG RPC handler 4 - Handling RPC call")
                --print("DEBUG RPC handler 5 - Function name:", fnName)
                --print("DEBUG RPC handler 6 - Call ID:", callId)
                --print("DEBUG RPC handler 7 - Arguments:", args and #args or 0)
                endpoint:handleCall(c, fnName, callId, args, callKey)
            elseif msgType == RPC_TYPE_DOC_REQUEST then
                local callId = ...
                --print("DEBUG RPC handler 8 - Handling doc request")
                endpoint:sendDoc(c, callId)
            elseif msgType == RPC_TYPE_PING then
                --print("DEBUG RPC handler 9 - Handling ping")
                c:send("rpc", RPC_TYPE_PING, "pong")
            end
            --print("DEBUG RPC handler 10 - Message handling complete")
        end)
    end, function(wake)
        -- maybe there should be some distinction between the endpoint access key and the device key
        return not endpoint.accessKey or wake == endpoint.accessKey
    end)
    
    if not success then
        --print("DEBUG api.expose 19 - Listener failed:", err)
        error("Failed to listen on port " .. port .. ": " .. err)
    end
    
    --print("DEBUG api.expose 20 - Endpoint listening")
    endpoint.listening = true
    api.endpoints[name] = endpoint
    
    return endpoint
end

function Endpoint:setAccessKey(key)
    self.accessKey = key
end

function Endpoint:setFunctionKeys(fnName, keys)
    if keys then
        if type(keys) == "table" then
            for i,k in pairs (keys) do
                if type(i) == "number" and type(k) == "string" then
                    keys[k]=true
                    keys[i]=nil
                end
            end
        else
            keys = {[tostring(keys)] = true}
        end
        self.functionKeys[fnName] = keys
    end
end

function Endpoint:exposeFunction(fnName, desc, keys)
    if not self.lib[fnName] then
        error("Function '" .. fnName .. "' not found in exposed library")
    end
    if type(self.lib[fnName]) ~= "function" then
        error("Exposed member '" .. fnName .. "' is not a function")
    end
    self.functionDocs[fnName] = desc or "No description"
    self:setFunctionKeys(fnName, keys)
end

function Endpoint:handleCall(conn, fnName, callId, args, callKey)
    --print("DEBUG handleCall 1 - Received RPC call for function:", fnName)
    --print("DEBUG handleCall 2 - Call ID:", callId)
    --print("DEBUG handleCall 3 - Arguments count:", args and #args or 0)
    
    -- Check if function is exposed
    --print("DEBUG handleCall 4 - Checking if function is exposed")
    if not self.functionDocs[fnName] then
        --print("DEBUG handleCall 5 - Function not exposed:", fnName)
        conn:send("rpc", RPC_TYPE_RESPONSE, callId, false, "Function not exposed: " .. fnName)
        return
    end
    --print("DEBUG handleCall 6 - Function is exposed")
    
    -- Check per-function key if set
    --print("DEBUG handleCall 7 - Checking function access key")
    -- local requiredKey = self.functionKeys[fnName]
    -- if requiredKey and ((callKey~=nil and callKey ~= requiredKey) or callKey == nil) then
    --     --print("DEBUG handleCall 8 - Access denied for function:", fnName)
    --     conn:send("rpc", RPC_TYPE_RESPONSE, callId, nil, "Access denied to function: " .. fnName)
    --     return
    -- end
    local requiredKeys = self.functionKeys[fnName]
    if requiredKeys then
        if not callKey then
            conn:send("rpc", RPC_TYPE_RESPONSE, callId, false, "Missing function key for: " .. fnName)
            return
        end
        if not requiredKeys[callKey] then
            conn:send("rpc", RPC_TYPE_RESPONSE, callId, false, "Access denied to function: " .. fnName)
            return
        end
    end
    --print("DEBUG handleCall 9 - Access granted")
    
    -- Call function
    --print("DEBUG handleCall 10 - Calling function with arguments")
    conn:send("rpc", RPC_TYPE_RESPONSE, callId, {pcall(self.lib[fnName], table.unpack(args or {}))})
end

function Endpoint:sendDoc(conn, callId)
    local doc = {}
    for fnName, desc in pairs(self.functionDocs) do
        doc[fnName] = {
            description = desc,
            requires_key = self.functionKeys[fnName] ~= nil
        }
    end
    conn:send("rpc", RPC_TYPE_DOC_RESPONSE, callId, doc)
end
-- NEW: Get all active connections
function Endpoint:getConnections()
    return self.connections
end
-- NEW: Get connection for a specific client
function Endpoint:getConnection(clientAddress)
    return self.connections[clientAddress]
end
-- NEW: Shutdown endpoint
function Endpoint:shutdown()
    if not self.listening then return end
    
    -- Stop listening
    tnet.stopListening(self.port)
    self.listening = false
    
    -- Close all connections
    for address, conn in pairs(self.connections) do
        conn:close()
    end
    self.connections = {}
    
    -- Remove from global registry
    api.endpoints[self.name] = nil
    return true
end

-- CLIENT SIDE
local RemoteProxy = {}
RemoteProxy.__index = RemoteProxy
function api.connect(endpointName, port, address, wakeKey, timeout, fnKeys)
    --print("DEBUG api.connect 1 - Starting connection process")
    timeout = timeout or 5
    --print("DEBUG api.connect 2 - Timeout set to:", timeout)
    
    -- Create tnet connection
    --print("DEBUG api.connect 3 - Creating tnet connection")
    local conn = tnet.connect(address, port, wakeKey, "api_client")
    conn.serial = {lib = "serialization", encode = "serialize", decode = "unserialize"}
    --print("DEBUG api.connect 4 - tnet connection object created")
    
    --print("DEBUG api.connect 5 - Initializing connection")
    local success, err = conn:init(timeout)
    --print("DEBUG api.connect 6 - Connection init result:", success, "Error:", err)
    
    if not success then
        --print("DEBUG api.connect 7 - Connection failed")
        error("Failed to connect to " .. address .. ":" .. port .. " - " .. (err or "timeout"))
    end
    
    --print("DEBUG api.connect 8 - Creating proxy object")
    -- Create proxy object
    local proxy = setmetatable({
        conn = conn,
        endpoint = endpointName,
        address = address,
        port = port,
        doc = nil,  -- lazy-loaded
        timeout = timeout,
        connected = true  -- Track connection state
    }, RemoteProxy)
    
    -- Optional: track in global client registry
    --print("DEBUG api.connect 9 - Registering client")
    local clientKey = address .. ":" .. port .. "/" .. endpointName
    api.clients[clientKey] = proxy
    --print("DEBUG api.connect 10 - Client registered with key:", clientKey)
    proxy:setFnKeyTable(fnKeys)
    --print("DEBUG api.connect 11 - Connection process complete")
    return proxy
end

function RemoteProxy:listDocumentation()
    if not self.doc then
        self:refreshDocumentation()
    end
    return self.doc
end

function RemoteProxy:refreshDocumentation()
    local callId = computer.uptime() .. "-" .. math.random(1000, 9999)
    local received = false
    local doc, err
    self.conn:expect(callId, function(_, result, error_msg)
        received = true
        if error_msg then
            err = error_msg
        else
            doc = result
        end
    end, 5)
    self.conn:send("rpc", RPC_TYPE_DOC_REQUEST, callId)
    local start = computer.uptime()
    while computer.uptime() - start < 5 and not received do
        os.sleep()
    end
    if not received then
        error("Timeout fetching documentation")
    end
    if err then
        error("Error fetching documentation: " .. err)
    end
    self.doc = doc
    return doc
end

-- Metamethod to allow remote.fn() syntax
function RemoteProxy:__index(key)
    -- First check if the key exists in the raw table
    local rawValue = rawget(self, key)
    if rawValue ~= nil then
        return rawValue
    end
    
    -- Then check if it's a method we own
    if RemoteProxy[key] then
        return RemoteProxy[key]
    end
    
    -- For remote functions, return a callable wrapper without checking documentation
    return function(...)
        local callKey = nil
        if self.keys and type(self.keys) == "table" then
            local keyVal = self.keys[key]
            if type(keyVal) == "string" then
                callKey = keyVal
            end
        end
        return self:callRemoteFunction(key, callKey, ...)
    end
end

function RemoteProxy:setFnKeyTable(newKeys) --functionName = key
    local oldKeys = self.keys
    if newKeys and type(newKeys) == "table" then
        self.keys = newKeys
    end
    return oldKeys
end

function RemoteProxy:callRemoteFunction(fnName, callKey, ...)
    if not self.connected then
        error("Connection is closed")
    end
    
    local callId = computer.uptime() .. "-" .. math.random(1000, 9999)
    local received = false
    local result, err
    
    self.conn:expect("rpc", function(_, _, msgType, responseCallId, response, errorMsg)
        if msgType == RPC_TYPE_RESPONSE and responseCallId == callId then
            --print("DEBUG callRemoteFunction 8 - Matching response received")
            received = true
            result = errorMsg and {false, errorMsg} or response
        -- else
            --print("DEBUG callRemoteFunction 11 - Non-matching response, ignoring")
        end
    end, 10)
    
    local args = table.pack(...)
    self.conn:send("rpc", RPC_TYPE_CALL, fnName, callId, args, callKey)
    
    local start = computer.uptime()
    local loopCount = 0
    while computer.uptime() - start < 10 and not received do
        loopCount = loopCount + 1
        os.sleep()
    end
    
    if not received then
        return false, ("Timeout calling remote function: " .. fnName)
    end
    
    if type(result) == "table" then
        local max_index = 0
        for k in pairs(result) do
            if type(k) == "number" and k > max_index then
                max_index = k
            end
        end
        
        -- Return all values up to max_index
        return table.unpack(result, 1, max_index)
    else
        return result
    end
end

function RemoteProxy:getConnection()
    return self.conn
end

function RemoteProxy:close()
    if not self.connected then return end
    
    self.conn:close()
    self.connected = false
    
    -- Remove from global registry
    local clientKey = self.address .. ":" .. self.port .. "/" .. self.endpoint
    api.clients[clientKey] = nil
    return true
end

return api