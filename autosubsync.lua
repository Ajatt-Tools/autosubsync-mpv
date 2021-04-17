-- Usage:
--  default keybinding: n
--  add the following to your input.conf to change the default keybinding:
--  keyname script_binding autosubsync-menu

local mp = require('mp')
local utils = require('mp.utils')
local mpopt = require('mp.options')
local menu = require('menu')
local ref_selector
local engine_selector
local track_selector

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

local function get_loaded_tracks(track_type)
    local result = {}
    local track_list = mp.get_property_native('track-list')
    for _, track in pairs(track_list) do
        if track.type == track_type then
            table.insert(result, track)
        end
    end
    return result
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

local function engine_is_set()
    if is_empty(config.subsync_tool) or config.subsync_tool == "ask" then
        return false
    else
        return true
    end
end

local function sync_subtitles(ref_sub_path)
    local reference_file_path = ref_sub_path or mp.get_property("path")
    local subtitle_path = get_active_subtitle_track_path()
    local engine_name = engine_selector:get_engine_name()
    local engine_path = config[engine_name .. '_path']

    if not file_exists(engine_path) then
        return notify(
                string.format("Can't find %s executable.\nPlease specify the correct path in the config.", engine_name),
                "error",
                5
        )
    end

    if not file_exists(subtitle_path) then
        return notify(
                table.concat {
                    "Subtitle synchronization failed:\nCouldn't find ",
                    subtitle_path or "external subtitle file."
                },
                "error",
                3
        )
    end

    local retimed_subtitle_path = mkfp_retimed(subtitle_path)

    notify(string.format("Starting %s...", engine_name), nil, 2)

    local ret
    if engine_name == "ffsubsync" then
        local args = { config.ffsubsync_path, reference_file_path, "-i", subtitle_path, "-o", retimed_subtitle_path }
        if not ref_sub_path then
            table.insert(args, '--reference-stream')
            table.insert(args, '0:' .. get_active_track('audio'))
        end
        ret = subprocess(args)
    else
        ret = subprocess { config.alass_path, reference_file_path, subtitle_path, retimed_subtitle_path }
    end

    if ret == nil then
        return notify("Parsing failed or no args passed.", "fatal", 3)
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
        return notify("Can't find ffmpeg executable.\nPlease specify the correct path in the config.", "error", 5)
    end

    local selected_track = track_selector:get_selected_track()
    local ref_sub_filepath
    if selected_track and selected_track.external then
        ref_sub_filepath = selected_track['external-filename']
    else
        ref_sub_filepath = utils.join_path(os_temp(), 'autosubsync_extracted.srt')
        notify("Extracting internal subtitles...", nil, 3)
        print(selected_track.num)
        local ret = subprocess {
            config.ffmpeg_path,
            "-hide_banner",
            "-nostdin",
            "-y",
            "-loglevel", "quiet",
            "-an",
            "-vn",
            "-i", mp.get_property("path"),
            "-map", "0:" .. (selected_track and selected_track['ff-index'] or 's'),
            "-f", "srt",
            ref_sub_filepath
        }
        if ret == nil or ret.status ~= 0 then
            return notify("Couldn't extract internal subtitle.\nMake sure the video has internal subtitles.", "error", 7)
        end
    end

    sync_subtitles(ref_sub_filepath)
    os.remove(ref_sub_filepath)
end

------------------------------------------------------------
-- Menu actions & bindings

ref_selector = menu:new {
    items = { 'Sync to audio', 'Sync to an internal subtitle', 'Cancel' },
    last_choice = 'audio',
    pos_x = 50,
    pos_y = 50,
    text_color = 'fff5da',
    border_color = '2f1728',
    active_color = 'ff6b71',
    inactive_color = 'fff5da',
}

function ref_selector:get_keybindings()
    return {
        { key = 'h', fn = function() self:close() end },
        { key = 'j', fn = function() self:down() end },
        { key = 'k', fn = function() self:up() end },
        { key = 'l', fn = function() self:act() end },
        { key = 'down', fn = function() self:down() end },
        { key = 'up', fn = function() self:up() end },
        { key = 'Enter', fn = function() self:act() end },
        { key = 'ESC', fn = function() self:close() end },
        { key = 'n', fn = function() self:close() end },
    }
end

function ref_selector:new(o)
    self.__index = self
    o = o or {}
    return setmetatable(o, self)
end

function ref_selector:get_ref()
    if self.selected == 1 then
        return 'audio'
    elseif self.selected == 2 then
        return 'sub'
    else
        return nil
    end
end

function ref_selector:act()
    self:close()

    if self.selected == 3 then
        return
    end

    engine_selector:init()
end

function ref_selector:call_subsync()
    if self.selected == 1 then
        sync_subtitles()
    elseif self.selected == 2 then
        sync_to_internal()
    end
end

function ref_selector:open()
    self.selected = 1
    for _, val in pairs(self:get_keybindings()) do
        mp.add_forced_key_binding(val.key, val.key, val.fn)
    end
    self:draw()
end

function ref_selector:close()
    for _, val in pairs(self:get_keybindings()) do
        mp.remove_key_binding(val.key)
    end
    self:erase()
end


------------------------------------------------------------
-- Engine selector

engine_selector = ref_selector:new {
    items = { 'ffsubsync', 'alass', 'Cancel' },
    last_choice = 'ffsubsync',
}

function engine_selector:init()
    if not engine_is_set() then
        engine_selector:open()
    else
        track_selector:init()
    end
end

function engine_selector:get_engine_name()
    return engine_is_set() and config.subsync_tool or self.last_choice
end

function engine_selector:act()
    self:close()

    if self.selected == 1 then
        self.last_choice = 'ffsubsync'
    elseif self.selected == 2 then
        self.last_choice = 'alass'
    elseif self.selected == 3 then
        return
    end

    track_selector:init()
end

------------------------------------------------------------
-- Track selector

track_selector = ref_selector:new { }

function track_selector:init()
    self.selected = 0

    if ref_selector:get_ref() == 'audio' then
        return ref_selector:call_subsync()
    end

    self.tracks = get_loaded_tracks(ref_selector:get_ref())

    if #self.tracks < 2 then
        return ref_selector:call_subsync()
    end

    self.items = {}
    for _, track in ipairs(self.tracks) do
        table.insert(
                self.items,
                string.format(
                        "%s #%s - %s%s",
                        (track.external and 'External' or 'Internal'),
                        track['ff-index'],
                        (track.lang or track.title:gsub('^.*%.', '')),
                        (track.selected and ' (active)' or '')
                )
        )
    end
    table.insert(self.items, "Cancel")
    self:open()
end

function track_selector:get_selected_track()
    if self.selected < 1 then
        return nil
    end
    return self.tracks[self.selected]
end

function track_selector:act()
    self:close()

    if self.selected == #self.items then
        return
    end

    ref_selector:call_subsync()
end

------------------------------------------------------------
-- Initialize the addon

local function init()
    for _, executable in pairs { 'ffmpeg', 'ffsubsync', 'alass' } do
        local config_key = executable .. '_path'
        config[config_key] = is_empty(config[config_key]) and find_executable(executable) or config[config_key]
    end
end

------------------------------------------------------------
-- Entry point

init()
mp.add_key_binding("n", "autosubsync-menu", function() ref_selector:open() end)
