# frozen_string_literal: true

module ::Moddashplugin
  class ResourceCategorySerializer < ::ApplicationSerializer
    attributes :id, :name, :slug, :color, :text_color, :description, :position, :parent_category_id
  end
end
