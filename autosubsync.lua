-- Usage:
--  default keybinding: n
--  add the following to your input.conf to change the default keybinding:
--  keyname script_binding autosubsync-menu

local utils = require('mp.utils')
local mpopt = require('mp.options')
local tool_select

-- Config
-- Options can be changed here or in a separate config file.
-- Config path: ~/.config/mpv/script-opts/autosubsync.conf
local config = {
    -- Change the following lines if the locations of executables differ from the defaults
    -- If set to empty, the path will be guessed.
    ffmpeg_path = "",
    ffsubsync_path = "",
    alass_path = "",

    -- Choose what tool to use. Allowed options: ffsubsync, alass, ask.
    -- If set to ask, the add-on will ask to choose the tool every time.
    subsync_tool = "ask",

    -- After retiming, tell mpv to forget the original subtitle track.
    unload_old_sub = true,
}
mpopt.read_options(config, 'autosubsync')

local function is_empty(var)
    return var == nil or var == '' or (type(var) == 'table' and next(var) == nil)
end

-- Snippet borrowed from stackoverflow to get the operating system
-- originally found at: https://stackoverflow.com/a/30960054
local os_name = (function()
    if os.getenv("HOME") == nil then
        return function()
            return "Windows"
        end
    else
        return function()
            return "*nix"
        end
    end
end)()

-- Courtesy of https://stackoverflow.com/questions/4990990/check-if-a-file-exists-with-lua
local function file_exists(filepath)
    if not filepath then
        return false
    end
    local f = io.open(filepath, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

local function find_executable(name)
    local os_path = os.getenv("PATH") or ""
    local fallback_path = utils.join_path("/usr/bin", name)
    local exec_path
    for path in os_path:gmatch("[^:]+") do
        exec_path = utils.join_path(path, name)
        if file_exists(exec_path) then
            return exec_path
        end
    end
    return fallback_path
end

local function notify(message, level, duration)
    level = level or 'info'
    duration = duration or 1
    mp.msg[level](message)
    mp.osd_message(message, duration)
end

local function subprocess(args)
    return mp.command_native {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = args
    }
end

local function get_active_track(track_type)
    local track_list = mp.get_property_native('track-list')
    for num, track in ipairs(track_list) do
        if track.type == track_type and track.selected == true then
            return num, track
        end
    end
    return nil
end

local function get_active_subtitle_track_path()
    local _, track = get_active_track('sub')
    if track and track.external == true then
        return track['external-filename']
    end
end

local function remove_extension(filename)
    return filename:gsub('%.%w+$', '')
end

local function get_extension(filename)
    return filename:match("^.+(%.%w+)$")
end

local function mkfp_retimed(sub_path)
    return table.concat { remove_extension(sub_path), '_retimed', get_extension(sub_path) }
end

local function sync_sub_fn(timed_sub_path)
    local reference_file_path = timed_sub_path or mp.get_property("path")
    local subtitle_path = get_active_subtitle_track_path()
    local subsync_tool = is_empty(config.subsync_tool) and tool_select.last_choice or 'ffsubsync'

    if not file_exists(config[subsync_tool .. '_path']) then
        notify(string.format(
                "Can't find %s executable.\nPlease specify the correct path in the config.",
                subsync_tool), "error", 5)
        return
    end

    if not file_exists(subtitle_path) then
        notify(table.concat {
            "Subtitle synchronization failed:\nCouldn't find ",
            subtitle_path or "external subtitle file."
        }, "error", 3)
        return
    end

    local retimed_subtitle_path = mkfp_retimed(subtitle_path)

    local ret
    if subsync_tool == "ffsubsync" then
        notify("Starting ffsubsync...", nil, 2)
        local args = { config.ffsubsync_path, reference_file_path, "-i", subtitle_path, "-o", retimed_subtitle_path }
        if not timed_sub_path then
            table.insert(args, '--reference-stream')
            table.insert(args, '0:' .. get_active_track('audio'))
        end
        ret = subprocess(args)
    else
        notify("Starting alass...", nil, 2)
        ret = subprocess { config.alass_path, reference_file_path, subtitle_path, retimed_subtitle_path }
    end

    if ret == nil then
        notify("Parsing failed or no args passed.", "fatal", 3)
        return
    end

    if ret.status == 0 then
        local old_sid = mp.get_property("sid")
        if mp.commandv("sub_add", retimed_subtitle_path) then
            notify("Subtitle synchronized.", nil, 2)
            if config.unload_old_sub then
                mp.commandv("sub_remove", old_sid)
            end
        else
            notify("Error: couldn't add synchronized subtitle.", "error", 3)
        end
    else
        notify("Subtitle synchronization failed.", "error", 3)
    end
end

local os_temp = (function()
    if os_name() == "Windows" then
        return function()
            return os.getenv('TEMP')
        end
    else
        return function()
            return '/tmp/'
        end
    end
end)()

local function sync_to_internal()
    if not file_exists(config.ffmpeg_path) then
        notify("Can't find ffmpeg executable.\nPlease specify the correct path in the config.", "error", 5)
        return
    end

    local extracted_sub_filename = utils.join_path(os_temp(), 'autosubsync_extracted.srt')

    notify("Extracting internal subtitles...", nil, 3)
    local ret = subprocess {
        config.ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "quiet",
        "-an",
        "-vn",
        "-i", mp.get_property("path"),
        "-f", "srt",
        extracted_sub_filename
    }

    if ret == nil or ret.status ~= 0 then
        notify("Couldn't extract internal subtitle.\nMake sure the video has internal subtitles.", "error", 7)
        return
    end

    sync_sub_fn(extracted_sub_filename)
    os.remove(extracted_sub_filename)
end

------------------------------------------------------------
-- Menu visuals

local assdraw = require('mp.assdraw')

local Menu = assdraw.ass_new()

function Menu:new(o)
    self.__index = self
    o = o or {}
    o.selected = o.selected or 1
    o.canvas_width = o.canvas_width or 1280
    o.canvas_height = o.canvas_height or 720
    o.pos_x = o.pos_x or 0
    o.pos_y = o.pos_y or 0
    o.rect_width = o.rect_width or 250
    o.rect_height = o.rect_height or 40
    o.active_color = o.active_color or 'ffffff'
    o.inactive_color = o.inactive_color or 'aaaaaa'
    o.border_color = o.border_color or '000000'
    o.text_color = o.text_color or 'ffffff'

    return setmetatable(o, self)
end

function Menu:set_position(x, y)
    self.pos_x = x
    self.pos_y = y
end

function Menu:font_size(size)
    self:append(string.format([[{\fs%s}]], size))
end

function Menu:set_text_color(code)
    self:append(string.format("{\\1c&H%s%s%s&\\1a&H05&}", code:sub(5, 6), code:sub(3, 4), code:sub(1, 2)))
end

function Menu:set_border_color(code)
    self:append(string.format("{\\3c&H%s%s%s&}", code:sub(5, 6), code:sub(3, 4), code:sub(1, 2)))
end

function Menu:apply_text_color()
    self:set_border_color(self.border_color)
    self:set_text_color(self.text_color)
end

function Menu:apply_rect_color(i)
    self:set_border_color(self.border_color)
    if i == self.selected then
        self:set_text_color(self.active_color)
    else
        self:set_text_color(self.inactive_color)
    end
end

function Menu:draw_text(i)
    local padding = 5
    local font_size = 25

    self:new_event()
    self:pos(self.pos_x + padding, self.pos_y + self.rect_height * (i - 1) + padding)
    self:font_size(font_size)
    self:apply_text_color(i)
    self:append(self.items[i])
end

function Menu:draw_item(i)
    self:new_event()
    self:pos(self.pos_x, self.pos_y)
    self:apply_rect_color(i)
    self:draw_start()
    self:rect_cw(0, 0 + (i - 1) * self.rect_height, self.rect_width, i * self.rect_height)
    self:draw_stop()
    self:draw_text(i)
end

function Menu:draw()
    self.text = ''
    for i, _ in ipairs(self.items) do
        self:draw_item(i)
    end

    mp.set_osd_ass(self.canvas_width, self.canvas_height, self.text)
end

function Menu:erase()
    mp.set_osd_ass(self.canvas_width, self.canvas_height, '')
end

function Menu:up()
    self.selected = self.selected - 1
    if self.selected == 0 then
        self.selected = #self.items
    end
    self:draw()
end

function Menu:down()
    self.selected = self.selected + 1
    if self.selected > #self.items then
        self.selected = 1
    end
    self:draw()
end

------------------------------------------------------------
-- Menu actions & bindings

local menu = Menu:new {
    items = { 'Sync to audio', 'Sync to an internal subtitle', 'Cancel' },
    pos_x = 50,
    pos_y = 50,
    text_color = 'fff5da',
    border_color = '2f1728',
    active_color = 'ff6b71',
    inactive_color = 'fff5da',
}

function menu:get_keybindings()
    return {
        { key = 'h', fn = function() self:close() end },
        { key = 'j', fn = function() self:down() end },
        { key = 'k', fn = function() self:up() end },
        { key = 'l', fn = function() self:act() end },
        { key = 'down', fn = function() self:down() end },
        { key = 'up', fn = function() self:up() end },
        { key = 'Enter', fn = function() self:act() end },
        { key = 'ESC', fn = function() self:close() end },
    }
end

function menu:new(o)
    self.__index = self
    o = o or {}
    return setmetatable(o, self)
end

function menu:should_open_tool_selection()
    return is_empty(config.subsync_tool) or config.subsync_tool == "ask"
end

function menu:act()
    self:close()

    if self.selected == 3 then
        return
    end

    if self:should_open_tool_selection() then
        tool_select:open()
        return
    end

    self:call_subsync()
end

function menu:call_subsync()
    if self.selected == 1 then
        sync_sub_fn()
    elseif self.selected == 2 then
        sync_to_internal()
    end
end

function menu:open()
    self.selected = 1
    for _, val in pairs(self:get_keybindings()) do
        mp.add_forced_key_binding(val.key, val.key, val.fn)
    end
    self:draw()
end

function menu:close()
    for _, val in pairs(self:get_keybindings()) do
        mp.remove_key_binding(val.key)
    end
    self:erase()
end


------------------------------------------------------------
-- Engine selector

tool_select = menu:new {
    items = { 'ffsubsync', 'alass', 'Cancel'},
    last_choice = 'ffsubsync'
}

function tool_select:act()
    self:close()

    if self.selected == 1 then
        self.last_choice = 'ffsubsync'
    elseif self.selected == 2 then
        self.last_choice = 'alass'
    elseif self.selected == 3 then
        return
    end

    menu:call_subsync()
end

------------------------------------------------------------
-- Initialize the addon

local function init()
    for _, executable in pairs {'ffmpeg', 'ffsubsync', 'alass'} do
        local config_key = executable .. '_path'
        config[config_key] = is_empty(config[config_key]) and find_executable(executable) or config[config_key]
    end
end

------------------------------------------------------------
-- Entry point

init()
mp.add_key_binding("n", "autosubsync-menu", function() menu:open() end)
