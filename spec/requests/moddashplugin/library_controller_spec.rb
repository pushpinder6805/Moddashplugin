# frozen_string_literal: true

RSpec.describe Moddashplugin::LibraryController do
  fab!(:root, :category_with_definition)
  fab!(:child) { Fabricate(:category, parent_category_id: root.id) }
  fab!(:member, :user)
  fab!(:moderator)
  fab!(:root_topic) { Fabricate(:topic, category: root) }
  fab!(:child_topic) { Fabricate(:topic, category: child) }

  before do
    SiteSetting.moddashplugin_enabled = true
    SiteSetting.moddashplugin_root_category_ids = root.id.to_s
  end

  def load_library(**params)
    get "/moddashplugin/library.json", params: { root_id: root.id }.merge(params)
  end

  it "includes resources in the root and its descendants, excluding category definitions" do
    sign_in(member)
    load_library
    expect(response.status).to eq(200)
    expect(response.parsed_body["categories"].map { |cat| cat["id"] }).to contain_exactly(
      root.id,
      child.id,
    )
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to contain_exactly(
      root_topic.id,
      child_topic.id,
    )
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end

  it "loads resources for administrators as well as regular members" do
    sign_in(Fabricate(:admin))
    load_library
    expect(response.status).to eq(200)
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to contain_exactly(
      root_topic.id,
      child_topic.id,
    )
  end

  it "does not discard real resources whose title starts with About the" do
    resource = Fabricate(:topic, category: child, title: "About the Medicaid eligibility rules")
    sign_in(member)
    load_library
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to include(resource.id)
  end

  it "includes every child even when Discourse uses lazy category loading" do
    SiteSetting.lazy_load_categories_groups = Group::AUTO_GROUPS[:everyone].to_s
    children = Fabricate.times(26, :category, parent_category_id: root.id)
    SiteSetting.max_category_nesting = 3
    grandchild = Fabricate(:category, parent_category_id: children.last.id)
    resource = Fabricate(:topic, category: grandchild)
    sign_in(member)
    load_library
    ids = response.parsed_body["categories"].map { |cat| cat["id"] }
    expect(ids).to include(*children.map(&:id), grandchild.id)
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to include(resource.id)
  end

  it "returns all topic pages in deterministic creation order without duplicates" do
    sign_in(member)
    stub_const(Moddashplugin::LibraryQuery, :PAGE_SIZE, 2) do
      extra = Fabricate(:topic, category: child, created_at: 1.day.ago)
      root_topic.update!(created_at: 2.days.ago)
      child_topic.update!(created_at: 2.days.ago)
      load_library
      first = response.parsed_body
      expect(first["topics"].map { |topic| topic["id"] }).to eq([extra.id, child_topic.id])
      expect(first["next_cursor"]).to be_present
      load_library(cursor: first["next_cursor"])
      expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to eq([root_topic.id])
      expect(response.parsed_body["next_cursor"]).to be_nil
    end
  end

  it "loads a library larger than the real 100-topic page size" do
    Fabricate.times(103, :topic, category: child)
    sign_in(member)
    load_library
    first = response.parsed_body
    expect(first["topics"].length).to eq(100)
    expect(first["next_cursor"]).to be_present
    load_library(cursor: first["next_cursor"])
    second = response.parsed_body
    expect(second["topics"].length).to eq(5)
    expect(second["next_cursor"]).to be_nil
    ids = (first["topics"] + second["topics"]).map { |topic| topic["id"] }
    expect(ids.uniq.length).to eq(105)
  end

  it "does not skip later resources when earlier topics are deleted between pages" do
    sign_in(member)
    stub_const(Moddashplugin::LibraryQuery, :PAGE_SIZE, 1) do
      root_topic.update!(created_at: 2.days.ago)
      load_library
      cursor = response.parsed_body["next_cursor"]
      child_topic.destroy!
      new_resource = Fabricate(:topic, category: child)
      load_library(cursor: cursor)
      expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to eq([root_topic.id])
      expect(response.parsed_body["topics"].map { |topic| topic["id"] }).not_to include(
        new_resource.id,
      )
    end
  end

  it "rejects forged cursors" do
    sign_in(member)
    load_library(cursor: "forged")
    expect(response.status).to eq(400)
  end

  it "binds cursors to the user, root and search" do
    sign_in(member)
    stub_const(Moddashplugin::LibraryQuery, :PAGE_SIZE, 1) do
      load_library
      cursor = response.parsed_body["next_cursor"]
      load_library(cursor: cursor, q: "different")
      expect(response.status).to eq(400)
      sign_in(moderator)
      load_library(cursor: cursor)
      expect(response.status).to eq(400)
    end
  end

  it "rechecks category permissions on subsequent pages" do
    group = Fabricate(:group)
    private_child = Fabricate(:private_category, parent_category_id: root.id, group: group)
    secret = Fabricate(:topic, category: private_child, created_at: 3.days.ago)
    group.add(member)
    sign_in(member)
    stub_const(Moddashplugin::LibraryQuery, :PAGE_SIZE, 1) do
      load_library
      cursor = response.parsed_body["next_cursor"]
      group.remove(member)
      ids = []
      while cursor
        load_library(cursor: cursor)
        expect(response.status).to eq(200)
        ids.concat(response.parsed_body["topics"].map { |topic| topic["id"] })
        cursor = response.parsed_body["next_cursor"]
      end
      expect(ids).not_to include(secret.id)
    end
  end

  it "does not leak restricted resources to members or moderators outside their group" do
    group = Fabricate(:group)
    private_child = Fabricate(:private_category, parent_category_id: root.id, group: group)
    secret = Fabricate(:topic, category: private_child)
    [member, moderator].each do |user|
      sign_in(user)
      load_library
      expect(response.status).to eq(200)
      expect(response.parsed_body["categories"].map { |cat| cat["id"] }).not_to include(
        private_child.id,
      )
      expect(response.parsed_body["topics"].map { |topic| topic["id"] }).not_to include(secret.id)
    end
    group.add(member)
    sign_in(member)
    load_library
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to include(secret.id)
  end

  it "rejects roots outside the configured library" do
    other = Fabricate(:category)
    sign_in(member)
    load_library(root_id: other.id)
    expect(response.status).to eq(404)
  end

  it "respects login_required and allows public libraries on public forums" do
    SiteSetting.login_required = true
    load_library
    expect(response.status).to eq(403)
    SiteSetting.login_required = false
    load_library
    expect(response.status).to eq(200)
  end

  it "returns no library data when the plugin is disabled" do
    sign_in(member)
    SiteSetting.moddashplugin_enabled = false
    load_library
    expect(response.status).to eq(404)
  end

  it "does not hide resources because the user muted a topic" do
    TopicUser.change(
      member.id,
      child_topic.id,
      notification_level: TopicUser.notification_levels[:muted],
    )
    sign_in(member)
    load_library
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to include(child_topic.id)
  end

  it "searches titles across the full library and treats SQL wildcards as literal text" do
    matching = Fabricate(:topic, category: child, title: "Income 100% rules for Medicaid")
    sign_in(member)
    load_library(q: "100%")
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to eq([matching.id])
  end

  it "starts with no saved order and returns newest resources first" do
    sign_in(member)
    root_topic.update!(created_at: 3.days.ago)
    child_topic.update!(created_at: 1.day.ago)
    load_library
    expect(response.status).to eq(200)
    expect(response.parsed_body["order_config"]).to eq({})
    expect(response.parsed_body["topics"].map { |topic| topic["id"] }).to eq(
      [child_topic.id, root_topic.id],
    )
  end

  it "hides unlisted topic IDs saved in a staff order from regular members" do
    hidden = Fabricate(:topic, category: child, visible: false)
    PluginStore.set("moddashplugin", "order_#{child.id}", [hidden.id, child_topic.id])
    sign_in(member)
    load_library
    expect(response.parsed_body.dig("order_config", child.id.to_s, "orderedIds")).to eq(
      [child_topic.id],
    )
  end

  it "includes server-resolved resource breadcrumbs in the topic response" do
    SiteSetting.lazy_load_categories_groups = Group::AUTO_GROUPS[:everyone].to_s
    Fabricate(:post, topic: child_topic)
    sign_in(member)
    get "/t/#{child_topic.id}.json"
    expect(response.status).to eq(200)
    context = response.parsed_body["moddashplugin_resource_context"]
    expect(context["root_id"]).to eq(root.id)
    expect(context["root_slug"]).to eq(root.slug)
    expect(context["breadcrumbs"].map { |cat| cat["id"] }).to eq([child.id])
  end

  describe "staff ordering" do
    def save_order(ids, category_id: child.id)
      put "/moddashplugin/categories/#{category_id}/order.json",
          params: {
            root_id: root.id,
            ordered_ids: ids,
          },
          as: :json
    end

    it "allows moderators to save category orders without an admin theme endpoint" do
      sign_in(moderator)
      save_order([child_topic.id])
      expect(response.status).to eq(200)
      expect(PluginStore.get("moddashplugin", "order_#{child.id}")).to eq([child_topic.id])
      load_library
      expect(response.parsed_body.dig("order_config", child.id.to_s, "orderedIds")).to eq(
        [child_topic.id],
      )
    end

    it "persists staff orders in the database and returns them to another user" do
      another = Fabricate(:topic, category: child)
      sign_in(moderator)
      save_order([child_topic.id, another.id])
      expect(response.status).to eq(200)
      expect(
        PluginStoreRow.find_by(plugin_name: "moddashplugin", key: "order_#{child.id}"),
      ).to be_present
      sign_in(member)
      load_library
      expect(response.parsed_body.dig("order_config", child.id.to_s, "orderedIds")).to eq(
        [child_topic.id, another.id],
      )
    end

    it "forbids members from saving orders" do
      sign_in(member)
      save_order([child_topic.id])
      expect(response.status).to eq(403)
      expect(PluginStore.get("moddashplugin", "order_#{child.id}")).to be_nil
    end

    it "rejects topics from other categories and malformed IDs" do
      sign_in(moderator)
      save_order([root_topic.id])
      expect(response.status).to eq(400)
      save_order(["invalid"])
      expect(response.status).to eq(400)
    end
  end
end
