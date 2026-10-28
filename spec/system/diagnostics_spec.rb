# frozen_string_literal: true

RSpec.describe "Resource diagnostics" do
  fab!(:admin)

  before do
    SiteSetting.moddashplugin_enabled = true
    SiteSetting.moddashplugin_diagnostics_enabled = true
    Moddashplugin::Diagnostics.record(
      {
        event: "load_failed",
        operation: "load",
        code: "timeout",
        trace_id: "support-reference-123",
        root_id: 10,
        duration_ms: 15_000,
      },
      user: admin,
    )
    sign_in(admin)
  end

  it "shows meaningful reasons and correlation references in plugin configuration" do
    visit("/admin/plugins/moddashplugin/diagnostics")
    expect(page).to have_css(".moddash-diagnostics h2", text: "Resource library diagnostics")
    expect(page).to have_text("Request timed out")
    find(".moddash-diagnostics details summary").click
    expect(page).to have_text("support-reference-123")
  end
end
