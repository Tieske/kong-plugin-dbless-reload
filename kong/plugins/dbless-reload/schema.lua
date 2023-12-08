local typedefs = require "kong.db.schema.typedefs"


local PLUGIN_NAME = "dbless-reload"


local schema = {
  name = PLUGIN_NAME,
  fields = {
    -- the 'fields' array is the top-level entry with fields defined by Kong
    { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer (typical for auth plugins)
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
        },
      },
    },
  },
}

return schema
