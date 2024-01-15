# DBless auto-reload

A Kong plugin that will watch for changes, and will automatically reload the Kong
instance. It will watch custom plugins, and the dbless config file.

For development purposes only! Use at your own risk.

The plugin will, on a timer interval, check the following:
- is the Kong instance DBless? if so, the dbless config file will be watched.
- are there any custom plugins loaded (anything other than `bundled` or `dbless-reload`)?
  if so, the folders where those plugins are located will be watched.


# Config

Install the plugin and set `KONG_PLUGINS=bundled,dbless-reload`. The plugin only needs to be added to the system. No need to configure it on a route or service etc.

Optionally set environment variable `KONG_RELOAD_CHECK_INTERVAL` to the check
interval in seconds (default value is `5` seconds). Set to `0` to disable the auto-reload.
> Note: changing this setting requires a Kong restart to apply it!

# Other

- tests are non-functional
