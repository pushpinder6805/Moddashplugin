# frozen_string_literal: true

RSpec.describe "Core features" do
  before do
    enable_current_plugin
    SiteSetting.moddashplugin_enabled = true
    SiteSetting.moddashplugin_root_category_ids = ""
  end

  it_behaves_like "having working core features"
end
