# frozen_string_literal: true

RSpec.describe "Moddashplugin admin discovery" do
  fab!(:admin)

  before do
    SiteSetting.moddashplugin_enabled = false
    sign_in(admin)
  end

  it "appears by name in the plugins list even while disabled" do
    get "/admin/plugins.json"
    expect(response.status).to eq(200)
    plugin = response.parsed_body["plugins"].find { |entry| entry["name"] == "moddashplugin" }
    expect(plugin).to be_present
    expect(plugin["humanized_name"]).to eq("Moddashplugin")
    expect(plugin["enabled"]).to eq(false)
    expect(plugin["has_settings"]).to eq(true)
  end

  it "exposes its own settings without the old component" do
    get "/admin/site_settings.json", params: { plugin: "moddashplugin" }
    expect(response.status).to eq(200)
    names = response.parsed_body["site_settings"].map { |setting| setting["setting"] }
    expect(names).to contain_exactly(
      "moddashplugin_enabled",
      "moddashplugin_root_category_ids",
      "moddashplugin_topics_per_category",
    )
  end
end
