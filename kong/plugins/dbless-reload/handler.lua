local plugin = {
  PRIORITY = 1000, -- set the plugin priority, which determines plugin execution order
  VERSION = "0.1", -- version in X.Y.Z format. Check hybrid-mode compatibility requirements.
}

local Timer = require("kong.plugins.dbless-reload.timer")
local pl_utils = require("pl.utils")
local pl_stringx = require("pl.stringx")
local pl_file = require("pl.file")
local pl_path = require("pl.path")
local pl_dir = require("pl.dir")
local cjson = require("cjson.safe")


local ENVVAR = "KONG_RELOAD_CHECK_INTERVAL"
local CHECK_INTERVAL = tonumber(os.getenv(ENVVAR) or "") or 5 -- in seconds
local MASTER_PID      -- the PID (number) of the nginx master process
local PLUGIN_LOCATIONS    -- a table of plugin names (strings) that should be watched for reloading
local CONFIG_FILE -- the dbless config file to watch (can be nil if not DBLess)
local PLUGIN_NAME = ({...})[1]:match("^kong%.plugins%.([^%.]+)") -- Grab pluginname from module name
local CACHE_FILENAME = "/tmp/"..PLUGIN_NAME.."-cache.json"
local LOG_PREFIX = "["..PLUGIN_NAME.."] "

-- TODO: commentout below line, since it is for testing only!
-- PLUGIN_NAME = PLUGIN_NAME .. "x" -- ensure it doesn't match so we can test reload on this plugins files



-- writes the text to the log in a box. Can be a string (will be splitted in lines), or multiple lines in a table.
local function box(text)
  if type(text) == "string" then
    text = pl_stringx.splitlines(text)
  end
  local length = 0
  for _, line in ipairs(text) do
    length = math.max(length, #line)
  end

  kong.log.info(LOG_PREFIX, "+",("-"):rep(length+2),"+")
  for _, line in ipairs(text) do
    kong.log.info(LOG_PREFIX, "| "..line..(" "):rep(length-#line).." |")
  end
  kong.log.info(LOG_PREFIX, "+",("-"):rep(length+2),"+")
end



-- returns the master process PID, or nil+err
local function get_pid()
  local pid, err = pl_utils.readfile(kong.configuration.nginx_pid)
  if not pid then
    return nil, err
  end

  local pid_num = tonumber(pid)
  if not pid then
    return nil, "failed to parse pid: "..tostring(pid)
  end

  return pid_num
end



-- returns the dbless config file to watch
local function get_dbless_config_file()
  if kong.configuration.database ~= "off" then
    return nil, "not running in DBLESS mode"
  end
  return kong.configuration.declarative_config
end



-- returns a table of plugin folders indexed by plugin-name. The plugins are the ones to watch.
local function get_plugin_locations_to_track()
  local plugins = {}
  for _, plugin in ipairs(kong.configuration.plugins) do
    if plugin ~= PLUGIN_NAME and plugin ~= "bundled" then
      local plugin_path, err = pl_path.package_path("kong.plugins."..plugin..".handler")
      if not plugin_path then
        return nil, "failed to find plugin path for plugin '"..plugin.."': "..tostring(err)
      end

      local plugin_path, _ = pl_path.splitpath(plugin_path) -- remove the filename, keep path only
      -- kong.log.info(LOG_PREFIX, "found plugin '"..plugin.."' at path: ", plugin_path)
      plugins[plugin] = plugin_path
    end
  end

  return plugins
end



-- writes cache file, return true, or nil+err
local function write_cache_file(data)
  local data, err = cjson.encode(data)
  if not data then
    return nil, "failed to encode cache file: " .. tostring(err)
  end

  local ok, err = pl_utils.writefile(CACHE_FILENAME, data)
  if not ok then
    return nil, "failed to write cache file: " .. tostring(err)
  end

  return true
end



-- returns the cached file, or nil+err.
-- if it doesn't exist, it will create one.
local function read_cached_file()
  if not pl_path.isfile(CACHE_FILENAME) then
    -- file doesn't exist, so looks like we started clean, create the file without
    -- actual files tracked being listed. Just the PID and the plugins to watch.
    assert(write_cache_file({
      pid = MASTER_PID,
      plugins = PLUGIN_LOCATIONS,
      dbless = CONFIG_FILE,
      files = nil, -- no files yet, marker to indicate NOT to compare
    }))
  end

  local data, err = pl_utils.readfile(CACHE_FILENAME)
  if not data then
    os.remove(CACHE_FILENAME) -- remove the file, so we can try again next time
    return nil, "failed to read cache file: " .. tostring(err)
  end

  local data, err = cjson.decode(data)
  if not data then
    os.remove(CACHE_FILENAME) -- remove the file, so we can try again next time
    return nil, "failed to json-decode cache file: " .. tostring(err)
  end

  return data
end



-- returns the current status of the tracked files, or nil+err
local function get_status()
  local status = {
    pid = MASTER_PID,
    plugins = PLUGIN_LOCATIONS,
    dbless = CONFIG_FILE,
    files = {}
  }

  -- read all the files and their modification times
  for plugin_name, plugin_path in pairs(status.plugins) do
    for filename, isdir in pl_dir.dirtree(plugin_path) do
      if not isdir then
        local mtime, err = pl_file.modified_time(filename)
        if not mtime then
          kong.log.err(LOG_PREFIX, "failed to read file modification time of '",filename,"': ", err)
        end
        status.files[filename] = mtime or 0
      end
    end
  end

  -- add the dbless config file if we have one
  if CONFIG_FILE then
    local mtime, err = pl_file.modified_time(CONFIG_FILE)
    if not mtime then
      kong.log.err(LOG_PREFIX, "failed to read dbless config file '"..CONFIG_FILE.."' modification time: ", err)
    end
    status.files[CONFIG_FILE] = mtime or 0
  end

  return status
end



-- reload our current Kong instace
local function reload_kong()
  kong.log.notice(LOG_PREFIX, "reloading Kong")
  os.execute("kill -1 " .. tostring(MASTER_PID))
  return true
end



-- check for changes and reload if necessary
local function check_for_updates()
  local cached_data, err = read_cached_file()
  if not cached_data then
    return kong.log.err(LOG_PREFIX, err)
  end

  local status = get_status()
  if status.pid ~= cached_data.pid then
    kong.log.notice(LOG_PREFIX, "nginx PID changed, cached file is outdated, writing a new one")
    assert(write_cache_file(status))
    return
  end

  if cached_data.files == nil then
    -- no files set yet, take current status, such that there are no changes to compare
    cached_data.files = status.files
  end

  -- check if the tracked files have changed, compare the file lists
  local cached_files = {}
  for k,v in pairs(cached_data.files) do cached_files[k] = v end
  local changed = {}
  for filename, mtime in pairs(status.files) do
    local mtime2 = cached_files[filename]
    if not mtime2 then
      changed[filename] = "was added"
    else
      if mtime2 ~= mtime then
        changed[filename] = "was modified"
      end
    end
    cached_files[filename] = nil
  end
  for filename, _ in pairs(cached_files) do
    changed[filename] = "was removed"
  end

  -- write new cache file
  assert(write_cache_file(status))

  if not next(changed) then
    return -- no changes
  end

  local result = {
    "the following files changed, reloading Kong:",
  }
  for k,v in pairs(changed) do
    result[#result+1] = ("file '%s' %s"):format(k, v)
  end

  box(result)
  reload_kong()
end



local ran_already = false

function plugin:init_worker()
  if ran_already then
    return -- sanity check: prevent starting timers multiple times
  else
    ran_already = true
  end

  MASTER_PID = assert(get_pid())
  PLUGIN_LOCATIONS = assert(get_plugin_locations_to_track())
  CONFIG_FILE = get_dbless_config_file() -- can be nil, if not dbless

  if CHECK_INTERVAL > 0 then
    local ok, err = Timer{
      interval = CHECK_INTERVAL,
      recurring = true,
      immediate = true,
      detached = true,
      expire = check_for_updates,
      shm_name = "kong",
      key_name = PLUGIN_NAME .. "-timer",
    }

    if not ok then
      kong.log.critical("failed to create timer: ", err)
      return
    end
    kong.log.notice(PLUGIN_NAME, " plugin is enabled, checking every ", CHECK_INTERVAL, " seconds")
  else
    kong.log.notice(PLUGIN_NAME, " plugin is disabled, set ", ENVVAR ," > 0 to enable it")
  end
end

return plugin
