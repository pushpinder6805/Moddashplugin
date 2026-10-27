# frozen_string_literal: true

module ::Moddashplugin
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace Moddashplugin
    config.autoload_paths << File.join(config.root, "lib")
  end
end
