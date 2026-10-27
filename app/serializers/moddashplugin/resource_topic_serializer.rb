# frozen_string_literal: true

module ::Moddashplugin
  class ResourceTopicSerializer < ::ApplicationSerializer
    attributes :id, :title, :slug, :category_id, :created_at
  end
end
