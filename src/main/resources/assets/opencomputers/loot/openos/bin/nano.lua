local shell = require("shell")
local fs = require("filesystem")
local tty = require("tty")
local core_cursor = require("core/cursor")
local unicode = require("unicode")
local kb = require("keyboard")
local keys = kb.keys

local args, ops = shell.parse(...)

local function usage(condition, msg)
  if condition then return
  elseif msg then io.stderr:write(msg, "\n") end
  io.stderr:write([[
Usage: edit <filename>
]])
  os.exit(1)
end

--------------------------------------------------------------------------------------
usage(not ops.help and #args == 1)
usage(io.stdout.tty, "stdout tty required")

local file = {lines = {}, line = 1, top = 1, lineoffset = 0, vindex = 0, find = {}, total = 0}
file.path = shell.resolve(args[1])
file.name = fs.name(file.path)
file.readonly = fs.get(file.path).isReadOnly() or ops.r
file.parent_path = fs.path(file.path)
file.exists = fs.exists(file.path)

usage(not fs.exists(file.parent_path) or fs.isDirectory(file.parent_path), string.format("Not a directory: %s", file.parent_path))
usage(not fs.isDirectory(file.path), string.format("file is a directory [%s]", file.path))
usage(file.exists or not file.readonly, string.format("cannot create file [%s] in readonly mode", file.path))

do
  local right, bottom = tty.getViewport()
  usage(right > 5, "resolution too small")
  file.box = {right = right, bottom = bottom - 1, height = bottom - 1}
end

--------------------------------------------------------------------------------------
local keybinds = {
  backspace  = {{"back"}},
  close      = {{"control", "x"}, {"control", "d"}},
  delete     = {{"delete"}},
  deleteLine = {{"control", "delete"}, {"shift", "delete"}},
  down       = {{"down"}},
  eol        = {{"end"}},
  find       = {{"control", "f"}},
  findnext   = {{"control", "g"}, {"control", "n"}, {"f3"}},
  home       = {{"home"}},
  left       = {{"left"}, {"control", "left"}},
  newline    = {{"enter"},{"numpadenter"}},
  pageDown   = {{"pageDown"}},
  pageUp     = {{"pageUp"}},
  right      = {{"right"}, {"control", "right"}},
  save       = {{"control", "s"}},
  up         = {{"up"}}
}

local function get_command(code)
  local control_down = kb.isControlDown()
  local shift_down = kb.isShiftDown()
  for command, rules in pairs(keybinds) do
    for _, rule_set in ipairs(rules) do
      local control_ok = not control_down
      local shift_ok = not shift_down
      local code_ok = false
      for _, rule_value in ipairs(rule_set) do
        if rule_value == "control" then control_ok = control_down
        elseif rule_value == "shift" then shift_ok = shift_down
        else code_ok = code == keys[rule_value] end
      end
      if control_ok and shift_ok and code_ok then return command end
    end
  end
end

local function finish_input(c)
  if not c.data:find("\n") then
    local previous_index = c.index
    c.index = c.len
    c:update("\n", false)
    c.index = previous_index
  end
  return true
end

local readonly_allowed = ";right;left;up;down;pageUp;pageDown;close;eol;home;"
local cursor = core_cursor.new({
  handle = function(self, name, char, code)
    if name == "key_down" then
      local dx, dy
      local prev = self.index == 0 and file.line > 1
      local next = self.index == self.len and file.line < #file.lines
      local command = get_command(code)
      if file.readonly and not readonly_allowed:find(string.format(";%s;", command)) then
        char, code, command = 0, 0, nil
      end
      if     command == "close" then return
      elseif command == "save"  then file:save()
      elseif file.line > 0 then
        if     command == "backspace"  and prev then dx, dy = file:remove(-1)
        elseif command == "delete"     and next then dx, dy = file:remove( 0)
        elseif command == "deleteLine"          then file.lines[file.line] = ""
                                                     dx, dy = file:remove(file.line < #file.lines and 0 or -1)
        elseif command == "down"                then dy = 1
        elseif command == "newline"             then self:update("\n", false)
                                                     return true
        elseif command == "find" or
               command == "findnext"            then file.find.ret = {self.index, file.line}
                                                     file.next = 0
                                                     if command == "find" then
                                                       file.lines[0] = ""
                                                     end
                                                     return finish_input(self)
        elseif command == "left"       and prev then dx, dy = -1, -1
        elseif command == "pageDown"            then dy = file.box.height
        elseif command == "pageUp"              then dy = -file.box.height
        elseif command == "right"      and next then dx, dy = 0, 1
        elseif command == "up"                  then dy = -1 end
      elseif command == "newline" or
             command == "down" or
             command == "up"                    then return file:finish()
      elseif command == "findnext"              then return file:next_find() end
      
      if dy then
        return file:move(dx, dy)
      elseif command then
        file.lineoffset = 0
      end
    elseif name == "clipboard" and file.readonly then
      name = nil
    elseif name == "touch" or name == "drag" or name == "drop" then
      local dy = code - file.line + file.top - 1
      if dy ~= 0 then
        return file:move(char - file.left, dy)
      end
    end
    local result = self.super.handle(self, name, char, code)
    if file.line > 0 then
      file:update_status()
    elseif result == true then
      file:update_search()
    else
      return file:finish()
    end
    return result
  end,
  echo = function(self, ...)
    local ret = self.super.echo(self, ...)
    if file.line > 0 and not file.pause and file.vindex ~= self.vindex then
      file.render_top = nil
      file:update()
    end
    return ret
  end
}, core_cursor.horizontal)

function file:save()
  if not self.readonly then
    self.total = 0
    if not fs.exists(file.parent_path) then
      fs.makeDirectory(file.parent_path)
    end
    local handle = assert(fs.open(self.path, "w"))
    for _, line in ipairs(self.lines) do
      self.total = self.total + #line + 1
      handle:write(line)
      handle:write("\n")
    end
    handle:close()
    self.modified = nil
    self.status_x = nil
    self.exists = true
  end
end

function file:update_status()
  local cx, cy = tty.getCursor()
  tty.setCursor(1, self.box.bottom + 1)
  if file.line == 0 then
    if file.lines[0] == "" then
      tty.setCursor(1, file.box.bottom + 1)
      io.write(string.format("\27[32mFind:\27[m \27[K"))
    end
    cx, cy = tty.getCursor()
  elseif self.lines[self.line] ~= cursor.data or self.modified then
    self.modified = false
    self.lines[self.line] = cursor.data
    io.write("\27[32m")
    for _, key in ipairs({"save", "close", "find"}) do
      local combo = (keybinds[key] or {})[1] or {}
      io.write(key:gsub("^.", string.upper), ": [", table.concat(combo, "+"), "] ")
    end
    io.write("\27[m\27[K")
  elseif (self.status_x ~= cursor.index or self.status_y ~= self.line) and self.modified == nil then
    local filename = "\27[32m\"" .. self.name .. "\""
    local condition = self.readonly and "\27[31m[readonly] \27[32m" or self.exists and "" or "\27[31m[New File] \27[32m"
    local position = string.format("%dL,%dC:%d,%d", #self.lines, self.total, self.line, cursor.index + 1)
    io.write(string.format('%s %s%s\27[m\27[K', filename, condition, position))
  end
  self.status_x, self.status_y = cursor.index, self.line
  tty.setCursor(cx, cy)
end

function file:update_search()
  local data = cursor.data
  if data ~= self.lines[0] then
    self.find = { ret = self.find.ret }
    self.lines[0] = data
    if #data > 0 then
      for l = 1, #self.lines do
        local start, line = 0, self.lines[l]
        while start < #line do
          local ok, where, to = pcall(string.find, line, cursor.data, start)
          if not ok or not where then break end
          -- select search result nearest current cursor line
          if not self.find.index and l >= self.find.ret[2] then
            self.find.index = #self.find
          end
          table.insert(self.find, {where, to, l})
          start = to + 1
        end
      end
      self.find.index = self.find.index or 0
    end
    self.render_top = nil -- cause refresh
    self:next_find()
  end
end

function file:next_find() -- index is nil when there are no search results
  local scroll_search = 2
  if #self.find > 0 then
    self.find.index = (self.find.index % #self.find) + 1
    local hit = self.find[self.find.index]
    self.find.ret = {hit[1] - 1, hit[3] - self.line}
    scroll_search = hit[2] - hit[1]
    self.render_top = nil -- this could be a find next while edit, need to refresh
  end
  local cx, cy = table.unpack(self.find.ret)
  self.top = math.min(cy, math.max(cy - self.box.height + 1, self.top))
  self.lineoffset = cx
  self:update(cx - self.box.right + scroll_search)
  return true
end

function file:finish()
  self:update() -- clear input
  local rx, ry = table.unpack(self.find.ret)
  self.find = {}
  self.render_top = nil -- clear the search results
  return self:move(rx, ry)
end

function file:encode(line, current_index)
  local cut = self.vindex == 0 and 0 or math.min(self.vindex, unicode.len(line))
  local result, last = {}, cut + 1
  for index, hit in ipairs(self.find) do
    local where, to, y = table.unpack(hit, 1, 3)
    if y == current_index and to >= last then
      local color = index == self.find.index and "\27[31;43m" or "\27[33;41m"
      table.insert(result, line:sub(last, where - 1))
      table.insert(result, color)
      table.insert(result, line:sub(math.max(last, where), to))
      table.insert(result, "\27[m")
      last = to + 1
    end
  end
  table.insert(result, line:sub(last))
  return result
end

function file:update(vindex)
  file.left = math.floor(math.log(math.min(self.box.height + self.top - 1, #self.lines), 10) + 3)
  if not self.pause and self.top ~= self.render_top then
    vindex = vindex and math.max(0, vindex + file.left)
    self.vindex = vindex or cursor.vindex
    self.render_top = self.top
    local cx, cy = tty.getCursor()
    local line_number_align = string.format("%%%dd|", file.left - 2)
    for y = 1, self.box.height do
      tty.setCursor(1, y)
      local current_index = self.top + y - 1
      local line = self.lines[current_index]
      if line then
        io.write(string.format(line_number_align, current_index))
      end
      if current_index ~= self.line then
        io.write(table.unpack(self:encode(line or "", current_index)))
        io.write("\27[K")
      end
    end
    tty.setCursor(cx, cy)
  end
  return file.left
end

function file:remove(dy)
  -- backspace(dy==1) and delete(dy==0)
  self.line = math.max(1, self.line + dy)
  cursor:update()
  cursor:update(self.lines[self.line] .. (table.remove(self.lines, self.line + 1) or ""), false)
  self.render_top = nil
  self.modified = true
  return unicode.len(self.lines[self.line]), 0
end

function file:move(x, dy)
  local y = math.min(#self.lines, math.max(1, self.line + dy))
  if dy ~= 0 and y == self.line then return true end
  -- if y == self.line then return true end
  self.lineoffset = x or math.max(self.lineoffset, cursor.index)
  self.next = y
  return finish_input(cursor)
end

--------------------------------------------------------------------------------------
io.write("\27[2J\27[32mloading ", file.path)
-- read file into lines
if file.exists then
  for line in io.lines(file.path) do
    table.insert(file.lines, line)
    file.total = file.total + #line + 1 -- +1 for the newline
  end
else
  file.lines = {""}
end
io.write("\27[m\27[2J\27[?7l")

while true do
  cursor:update()
  if file.line > 0 then
    file.top = math.min(file.line, math.max(file.line - file.box.height + 1, file.top))
    tty.setCursor(file:update(), file.line - file.top + 1)
    cursor:update(file.lines[file.line], false)
    file.pause = true
    local target = file.lineoffset == -1 and cursor.len or file.lineoffset
    cursor:scroll(math.max(0, math.min(cursor.len - 2, file.vindex) - cursor.vindex), target)
    file.pause = nil
  else
    cursor.next = file.lines[0]
    file.lines[0] = "" -- silly hack to get the search highlight to recolor
  end

  file:update_status()
  tty.window.cursor = cursor
  local result = io.read()
  if not result then
    break
  end
  file.lines[file.line] = result:gsub("\13?\10$", "")

  -- newlines leave file.next nil
  if not file.next then
    file.modified = true
    file.render_top = nil
    file.next = file.line + 1
    file.lineoffset = 0
    table.insert(file.lines, file.next, cursor.next or "")
    cursor.next = ""
  end

  file.line, file.next = file.next, nil
end

io.write("\27[?7h\27[2J")

--[[
  features todo
  1. should cursor handle be based on command words? that'd make it quite configurable...
    > perhaps custom commands would have to have a custom handler, yeah, that makes sense
    > you can't expect made up command words to have behavior
  
  2. shift-f3 find in reverse

  3. isolate of cursor hack functions that read or write fields outside the api

  it's a mess, and probably should just have fewer, simpler methods
  
]]--
