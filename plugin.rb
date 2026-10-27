# frozen_string_literal: true

# name: moddashplugin
# about: Resource Library with complete, permission-aware category and topic loading.
# version: 0.1.0
# authors: Pushpender Singh
# url: https://github.com/pushpinder6805/Moddashplugin
# required_version: 2026.10.0-latest

enabled_site_setting :moddashplugin_enabled
register_asset "stylesheets/common/resource-library.scss"

module ::Moddashplugin
  PLUGIN_NAME = "moddashplugin"
end

require_relative "lib/moddashplugin/engine"
