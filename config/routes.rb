# frozen_string_literal: true

Moddashplugin::Engine.routes.draw do
  get "/library" => "library#index", :defaults => { format: :json }
  put "/categories/:category_id/order" => "library#update_order", :defaults => { format: :json }
end

Discourse::Application.routes.draw { mount ::Moddashplugin::Engine, at: "/moddashplugin" }
