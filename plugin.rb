# frozen_string_literal: true

# name: moddashplugin
# about: Resource Library with complete, permission-aware category and topic loading.
# version: 0.2.0
# authors: Pushpender Singh
# url: https://github.com/pushpinder6805/Moddashplugin
# required_version: 2026.10.0-latest

enabled_site_setting :moddashplugin_enabled
register_asset "stylesheets/common/resource-library.scss"

module ::Moddashplugin
  PLUGIN_NAME = "moddashplugin"
end

require_relative "lib/moddashplugin/engine"

after_initialize do
  add_to_serializer(:topic_view, :moddashplugin_resource_context) do
    Moddashplugin::LibraryQuery.topic_context(scope, object.topic.category_id)
  end
end
