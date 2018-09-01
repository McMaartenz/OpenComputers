local keywords = {}

for _, keyword in ipairs({
  "and","break","do","else","elseif","end","false","for","function","goto","if",
  "in","local","nil","not","or","repeat","return","then","true","until","while"}) do
  table.insert(keywords, {"%W"..keyword.."%W", 35, 40})
end

for _, keyword in ipairs({
  "io","math","require","table","string","_G","_ENV","package","os","dofile","load",
  "loadfile","pairs","ipairs","next","setmetatable","getmetatable","debug","tostring",
  "type","checkArg","print","assert","tonumber","coroutine","pcall","xpcall","rawlen",
  "error","rawget","rawget", "%d"}) do
  table.insert(keywords, {"%W"..keyword.."%W", 33, 40})
end

table.insert(keywords, {"[^\"]\"[^\"]*\"[^\"]", 31, 40})
table.insert(keywords, {"[^-]%-%-.*", 36, 40})

function _ENV.encode(line, colors)
  if #line == 0 then return end
  line = " " .. line .. " "
  for _, rule in ipairs(keywords) do
    local last = 0
    local color = string.format("\27[%d;%dm", rule[2], rule[3])
    while last < #line do
      local ok, start_index, end_index = pcall(string.find, line, rule[1], last + 1)
      if not ok or not start_index then break end
      for i=start_index + 1, end_index - 1 do
        colors[i - 1] = color
      end
      last = end_index - 1
    end
  end
end
