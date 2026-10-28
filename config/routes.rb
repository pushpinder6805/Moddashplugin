# frozen_string_literal: true

Moddashplugin::Engine.routes.draw do
  post "/diagnostics" => "diagnostic_reports#create", :defaults => { format: :json }
  get "/admin/diagnostics" => "admin_diagnostics#index", :defaults => { format: :json }
  delete "/admin/diagnostics" => "admin_diagnostics#destroy", :defaults => { format: :json }
  get "/library" => "library#index", :defaults => { format: :json }
  put "/categories/:category_id/order" => "library#update_order", :defaults => { format: :json }
end

Discourse::Application.routes.draw { mount ::Moddashplugin::Engine, at: "/moddashplugin" }
