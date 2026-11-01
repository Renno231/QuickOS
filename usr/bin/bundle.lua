-- bundle: pack files into one stream and unpack them again.
-- A raw bundle is "OCB1", then per file string.pack(">s2I4",path,size) and its bytes,
-- then an empty path. A compressed bundle is an LZ4 frame (lz4_frame) of a raw bundle.
local fs=require("filesystem")
local shell=require("shell")

-- Shared by `bundle unpack` and the self-extracting stub, so it uses only fs and io.
local READER=[[
local fs=...
return function(f,root,each)
  local function read(n) local s=n>0 and f:read(n) or "";if #(s or "")<n then error("truncated bundle",0) end;return s end
  if f:read(4)~="OCB1" then error("not a bundle",0) end
  local count=0
  while true do
    local path=read(string.unpack(">I2",read(2)))
    if path=="" then return count end
    local size=string.unpack(">I4",read(4))
    if ("/"..path.."/"):find("/%.%./") then error("unsafe path in bundle: "..path,0) end
    each(path,size)
    local out
    if root then
      local dest=fs.concat(root,path);fs.makeDirectory(fs.path(dest))
      local err;out,err=io.open(dest,"wb");if not out then error(dest..": "..tostring(err),0) end
    end
    while size>0 do local n=math.min(size,8192);local s=read(n);if out then out:write(s) end;size=size-n end
    if out then out:close() end
    count=count+1
  end
end
]]

local args,opts=shell.parse(...)
local command,file=args[1]
local paths,exclude={},{}
local function usage()
  print("Usage: bundle pack DIR [--out=FILE] [--raw] [--sfx]")
  print("       bundle pack FILE PATH... [--root=DIR] [--raw] [--sfx]")
  print("       bundle unpack FILE [--root=DIR]")
  print("       bundle list FILE")
  print("pack DIR reads DIR/bundle.cfg, e.g. {name=\"mes\",paths={\"usr\",\"etc\"},exclude={}},")
  print("and writes NAME.bundle beside DIR. pack FILE PATH... stores PATHs relative to")
  print("--root (default: working directory). Bundles are compressed with lz4_frame when")
  print("it is installed, unless --raw or --sfx. unpack writes under --root (default: /).")
  print("An --sfx bundle (NAME.lua) unpacks itself: run it, with the same --root option.")
  print("Example: bundle pack /home/myproject")
  print("         then on the other machine: bundle unpack /home/myproject.bundle")
end
if not args[2] or (command~="pack" and command~="unpack" and command~="list") then return usage() end

local ok,frame=pcall(require,"lz4_frame");if not ok then frame=nil end
local read=load(READER,"=bundle reader")(fs)

local function pack(root,compress,skip)
  fs.makeDirectory(fs.path(file))
  local out,err=(compress and frame or io).open(file,"wb");if not out then error(file..": "..tostring(err),0) end
  local count=0
  -- rel is the file's path under root; as is the path it is stored under.
  local function add(rel,as)
    local full=fs.concat(root,rel)
    if full==file or full==skip or exclude[full] then return end
    if fs.isDirectory(full) then
      local names={};for name in fs.list(full) do names[#names+1]=(name:gsub("/$","")) end;table.sort(names)
      for _,name in ipairs(names) do add(rel=="" and name or fs.concat(rel,name),as=="" and name or fs.concat(as,name)) end
      return
    end
    local f=assert(io.open(full,"rb"))
    out:write(string.pack(">s2I4",as,fs.size(full)))
    for chunk in function() return f:read(8192) end do out:write(chunk) end
    f:close();print(as);count=count+1
    os.sleep(0)
  end
  local done,err=pcall(function()
    out:write("OCB1")
    -- An entry is a path, or {path,place} to store it under another path.
    for _,entry in ipairs(paths) do
      local path,place=entry,nil
      if type(entry)=="table" then path,place=entry[1],entry[2] end
      local full=fs.canonical(path:sub(1,1)=="/" and path or fs.concat(root,path))
      if not (root=="/" or full==root or full:sub(1,#root+1)==root.."/") then error(path.." is not inside "..root,0) end
      if not fs.exists(full) then error("no such file: "..full,0) end
      local rel=full==root and "" or full:sub(root=="/" and 2 or #root+2)
      if place and (place=="" or place:sub(1,1)=="/" or ("/"..place.."/"):find("/%.%./")) then
        error("bad place for "..path..": "..place,0)
      end
      add(rel,place or rel)
    end
    out:write(string.pack(">s2",""))
  end)
  out:close()
  if not done then fs.remove(file);error(err,0) end
  return count
end

-- A self-extractor is a Lua stub followed by the raw bundle inside a long comment;
-- the comment level is one more than the longest run of "=" in the bundle.
local function sfx(root)
  local final=file;file=final..".tmp"
  local done,count=pcall(pack,root,false,final);file=final
  if not done then error(count,0) end
  local data=assert(io.open(final..".tmp","rb"));local run,longest=0,0
  for chunk in function() return data:read(8192) end do
    local lead=#chunk:match("^=*")
    if lead==#chunk then run=run+lead else
      longest=math.max(longest,run+lead)
      for r in chunk:gmatch("=+") do longest=math.max(longest,#r) end
      run=#chunk:match("=*$")
    end
  end
  local level=string.rep("=",math.max(longest,run)+1)
  local stub="local OFFSET=0000000000\nlocal read=(function(...)\n"..READER.."\nend)(require('filesystem'))\n"..[[
local args,opts=require('shell').parse(...)
local f=assert(io.open(debug.getinfo(1,'S').source:sub(2),'rb'));f:seek('set',OFFSET)
local ok,count=pcall(read,f,require('shell').resolve(opts.root or '/'),function(path) print(path) end)
f:close()
if not ok then io.stderr:write('unpack: '..tostring(count)..'\n') else print(count..' files') end
]].."--["..level.."[\n"
  stub=stub:gsub("OFFSET=0000000000",("OFFSET=%010d"):format(#stub),1)
  local out=assert(io.open(final,"wb"));out:write(stub)
  data:seek("set",0)
  for chunk in function() return data:read(8192) end do out:write(chunk) end
  out:write("]"..level.."]\n");out:close();data:close();fs.remove(final..".tmp")
  return count
end

-- Opens a bundle positioned at its "OCB1" header, failing before anything is written.
local function open()
  local f,err=io.open(file,"rb");if not f then error(file..": "..tostring(err),0) end
  if f:read(4)~="\4\34\77\24" then f:seek("set",0);return f end
  f:close()
  if not frame then error("bundle is compressed and lz4_frame is not installed",0) end
  return assert(frame.open(file,"rb"))
end

local done,result=pcall(function()
  if command=="pack" then
    local root
    if args[3] then
      file,root=shell.resolve(args[2]),shell.resolve(opts.root or ".");paths={table.unpack(args,3)}
    else
      root=shell.resolve(args[2])
      local f=io.open(fs.concat(root,"bundle.cfg"),"rb");if not f then error("no bundle.cfg in "..root,0) end
      local cfg=require("serialization").unserialize(f:read("*a") or "");f:close()
      if type(cfg)~="table" or type(cfg.paths)~="table" or not cfg.paths[1] then error(root.."/bundle.cfg needs paths={...}",0) end
      paths=cfg.paths
      for _,path in ipairs(cfg.exclude or {}) do exclude[fs.concat(root,path)]=true end
      file=shell.resolve(opts.out or fs.concat(fs.path(root),(cfg.name or fs.name(root))..(opts.sfx and ".lua" or ".bundle")))
    end
    if opts.sfx then return sfx(root) end
    if not frame and not opts.raw then print("lz4_frame not installed: writing a raw bundle") end
    return pack(root,frame~=nil and not opts.raw)
  end
  file=shell.resolve(args[2])
  local f=open()
  local done,count=pcall(read,f,command=="unpack" and shell.resolve(opts.root or "/") or nil,function(path,size)
    print(command=="list" and string.format("%8d  %s",size,path) or path)
  end)
  f:close();if not done then error(count,0) end
  return count
end)
if not done then return io.stderr:write("bundle: "..tostring(result).."\n") end
print(result.." files")
