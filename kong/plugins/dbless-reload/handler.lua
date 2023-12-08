
local plugin = {
  PRIORITY = 1000, -- set the plugin priority, which determines plugin execution order
  VERSION = "0.1", -- version in X.Y.Z format. Check hybrid-mode compatibility requirements.
}

local ran_already = false

local Timer = require("kong.plugins.dbless-reload.timer")
local pl_utils = require("pl.utils")
local pl_file = require("pl.file")
local interval = tonumber(os.getenv("KONG_DBLESS_RELOAD_CHECK_INTERVAL") or "")
local config_filename
local config_filename_mtime = 0
local nginx_pid

local function timer_callback()
  local new_config_filename_mtime, err = pl_file.modified_time(config_filename)
  if not new_config_filename_mtime then
    kong.log.err("failed to read config file modification time: ", err)
    return
  end

  if new_config_filename_mtime == config_filename_mtime then
    return -- unchanged, nothing to do
  end

  -- record new time and reload nginx
  kong.log.notice("config file changed, reloading nginx to activate changes")
  config_filename_mtime = new_config_filename_mtime
  os.execute("kill -1 "..nginx_pid)
end


function plugin:init_worker()
  if ran_already then
    return
  end
  ran_already = true
  interval = interval or 5
  config_filename = kong.configuration.declarative_config

  if kong.configuration.database ~= "off" then
    kong.log.warn("dbless-reloader-plugin is enabled, but not running in DBLESS mode")
  end

  local err
  nginx_pid, err = pl_utils.readfile(kong.configuration.nginx_pid)
  if not nginx_pid then
    kong.log.critical("failed to read nginx pid file: ", err)
    return
  end

  config_filename_mtime = pl_file.modified_time(config_filename)

  kong.log.notice("check interval: ", interval," seconds, file: ", config_filename, ", nginx pid: ", nginx_pid)

  local ok, err = Timer{
    interval = interval,
    recurring = true,
    detached = true,
    expire = timer_callback,
    shm_name = "kong",
    key_name = "dbless-reload-timer",
  }

  if not ok then
    kong.log.critical("failed to create timer: ", err)
    return
  end
end

return plugin
