local event = require("event")
local fs = require("filesystem")
local shell = require("shell")
local tmp = require("computer").tmpAddress()

local pendingAutoruns = {}

local function onComponentAdded(_, address, componentType)
  if componentType == "filesystem" and tmp ~= address then
    local proxy = fs.proxy(address)
    if proxy then
      local name = address:sub(1, 3)
      while fs.exists(fs.concat("/mnt", name)) and
            name:len() < address:len() -- just to be on the safe side
      do
        name = address:sub(1, name:len() + 1)
      end
      name = fs.concat("/mnt", name)
      fs.mount(proxy, name)
      if fs.isAutorunEnabled() then
        local file = shell.resolve(fs.concat(name, "autorun"), "lua") or
                      shell.resolve(fs.concat(name, ".autorun"), "lua")
        if file then
          local run = {file, _ENV, proxy}
          if pendingAutoruns then
            table.insert(pendingAutoruns, run)
          else
            xpcall(shell.execute, event.onError, table.unpack(run))
          end
        end
      end
    end
  end
end

local function onComponentRemoved(_, address, componentType)
  if componentType == "filesystem" then
    if fs.get(shell.getWorkingDirectory()).address == address then
      shell.setWorkingDirectory("/")
    end
    fs.umount(address)
  end
end

event.listen("init", function()
  cprint("init", #pendingAutoruns)
  local home, pref = not fs.get("/home").isReadOnly()
  for _, run in ipairs(pendingAutoruns) do
    xpcall(shell.execute, event.onError, table.unpack(run))
    cprint("run: ", tostring(run[1]))
    if not run[3].isReadOnly() and not home then
      cprint("rw disk and no home")
      local new_home = run[3].exists("home")
      if new_home or not pref then
        pref = fs.concat(fs.path(run[1]), "home")
        home = new_home
      end
    end
  end
  if pref then
    fs.makeDirectory(pref)
    fs.mount(fs.proxy(pref, {bind=true}), "/home")
  end
  pendingAutoruns = nil
  return false
end)

event.listen("component_added", onComponentAdded)
event.listen("component_removed", onComponentRemoved)

require("package").delay(fs, "/lib/core/full_filesystem.lua")
