# DBless auto-reload

A hacky Kong plugin that will watch the config file for a DBless instance of
kong, and will automatically reload the Kong node when the file (timestamp)
changed.

This is a hack! use at your own risk.

# Config

set environment variable `KONG_DBLESS_RELOAD_CHECK_INTERVAL` to the check
interval in seconds. Default value is `5` seconds.

The plugin only needs to be added to the system. No need to configure it on a route or service etc.

Install the plugin and set `KONG_PLUGINS=bundled,dbless-reload`.

# other

- tests are non-functional
