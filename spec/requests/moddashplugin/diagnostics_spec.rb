# frozen_string_literal: true

RSpec.describe "Moddashplugin diagnostics" do
  fab!(:member, :user)
  fab!(:admin)
  fab!(:root, :category)

  before do
    SiteSetting.moddashplugin_enabled = true
    SiteSetting.moddashplugin_diagnostics_enabled = true
    SiteSetting.moddashplugin_root_category_ids = root.id.to_s
  end

  def payload
    {
      event_id: SecureRandom.uuid,
      occurred_at: Time.now.utc.iso8601(3),
      event: "load_failed",
      operation: "load",
      code: "timeout",
      trace_id: "reference-12345",
      root_id: root.id,
      duration_ms: 15_000,
      topics: 100,
      expected_topics: 150,
    }
  end

  def report(data = payload)
    post "/moddashplugin/diagnostics.json", params: { events: [data] }, as: :json
  end

  it "captures a member's failure centrally without private text or spoofed identity" do
    sign_in(member)
    report(
      payload.merge(
        username: "fake-admin",
        user_id: admin.id,
        role: "admin",
        message: "private text",
        q: "secret search",
        url: "/t/private-topic/123",
        stack: "sensitive stack",
      ),
    )
    expect(response.status).to eq(204)
    entry = Moddashplugin::Diagnostics.entries.first
    expect(entry["username"]).to eq(member.username)
    expect(entry["role"]).to eq("member")
    expect(entry["code"]).to eq("timeout")
    expect(entry["topics"]).to eq(100)
    expect(entry["expected_topics"]).to eq(150)
    expect(entry.to_json).not_to include(
      "secret search",
      "private text",
      "sensitive stack",
      "fake-admin",
      "/t/private-topic",
    )
  end

  it "deduplicates a batch retried after a lost reporting response" do
    sign_in(member)
    data = payload
    2.times { report(data) }
    expect(Moddashplugin::Diagnostics.entries.length).to eq(1)
  end

  it "allows administrators, but not members, to inspect reports" do
    Moddashplugin::Diagnostics.record(payload, user: member)
    sign_in(member)
    get "/moddashplugin/admin/diagnostics.json"
    expect(response.status).to eq(404)
    sign_in(admin)
    get "/moddashplugin/admin/diagnostics.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["entries"].length).to eq(1)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "keeps reports accessible to administrators after disabling the library" do
    Moddashplugin::Diagnostics.record(payload, user: member)
    SiteSetting.moddashplugin_enabled = false
    sign_in(admin)
    get "/moddashplugin/admin/diagnostics.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["entries"].length).to eq(1)
  end

  it "stops collecting when diagnostics are switched off" do
    SiteSetting.moddashplugin_diagnostics_enabled = false
    sign_in(member)
    report
    expect(response.status).to eq(204)
    expect(Moddashplugin::Diagnostics.entries).to be_empty
  end

  it "rejects invalid batches and ignores unknown events" do
    sign_in(member)
    post "/moddashplugin/diagnostics.json", params: { events: Array.new(11) { payload } }, as: :json
    expect(response.status).to eq(400)
    report(payload.merge(event: "arbitrary-event"))
    expect(response.status).to eq(204)
    expect(Moddashplugin::Diagnostics.entries).to be_empty
  end

  it "rate limits collection without storing a rejected report" do
    sign_in(member)
    RateLimiter.any_instance.stubs(:performed!).returns(false)
    report
    expect(response.status).to eq(429)
    expect(Moddashplugin::Diagnostics.entries).to be_empty
  end

  it "records actual server failures with a correlated request and trace ID" do
    sign_in(member)
    get "/moddashplugin/library.json",
        params: {
          root_id: root.id + 999_999,
        },
        headers: {
          "X-Moddash-Trace-ID" => "reference-server-error",
        }
    expect(response.status).to eq(404)
    entry = Moddashplugin::Diagnostics.entries.first
    expect(entry["source"]).to eq("server")
    expect(entry["code"]).to eq("not_found")
    expect(entry["status"]).to eq(404)
    expect(entry["trace_id"]).to eq("reference-server-error")
    expect(entry["request_id"]).to be_present
  end

  it "does not mask the original server failure if diagnostic storage fails" do
    PluginStore.stubs(:set).raises(IOError, "storage unavailable")
    sign_in(member)
    get "/moddashplugin/library.json", params: { root_id: root.id + 999_999 }
    expect(response.status).to eq(404)
  end

  it "caps stored history and purges expired reports on the next report" do
    stub_const(Moddashplugin::Diagnostics, :MAX_ENTRIES, 3) do
      5.times { Moddashplugin::Diagnostics.record(payload, user: member) }
      expect(Moddashplugin::Diagnostics.entries.length).to eq(3)
      row = PluginStoreRow.where(plugin_name: Moddashplugin::Diagnostics::NAMESPACE).first
      old = PluginStore.cast_value(row.type_name, row.value)
      old["received_at"] = 15.days.ago.utc.iso8601(3)
      PluginStore.set(Moddashplugin::Diagnostics::NAMESPACE, row.key, old)
      Moddashplugin::Diagnostics.record(payload, user: member)
      expect(PluginStoreRow.exists?(id: row.id)).to eq(false)
      expect(Moddashplugin::Diagnostics.entries.length).to eq(3)
    end
  end

  it "clears only diagnostics and preserves saved resource orders" do
    PluginStore.set("moddashplugin", "order_#{root.id}", [7, 8])
    Moddashplugin::Diagnostics.record(payload, user: member)
    sign_in(member)
    delete "/moddashplugin/admin/diagnostics.json"
    expect(response.status).to eq(404)
    sign_in(admin)
    delete "/moddashplugin/admin/diagnostics.json"
    expect(response.status).to eq(204)
    expect(Moddashplugin::Diagnostics.entries).to be_empty
    expect(PluginStore.get("moddashplugin", "order_#{root.id}")).to eq([7, 8])
  end

  it "returns permission-aware expected counts without exposing hidden resources" do
    Fabricate(:topic, category: root)
    sign_in(member)
    get "/moddashplugin/library.json", params: { root_id: root.id }
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("diagnostics", "expected_topics")).to eq(1)
    expect(response.parsed_body.dig("diagnostics", "categories")).to eq(1)
  end
end
