# frozen_string_literal: true

RSpec.describe "Resource library", type: :system do
  fab!(:member, :user)
  fab!(:root, :category)
  fab!(:child) { Fabricate(:category, parent_category_id: root.id) }
  fab!(:resource) { Fabricate(:post, topic: Fabricate(:topic, category: child)) }

  before do
    SiteSetting.moddashplugin_enabled = true
    SiteSetting.moddashplugin_root_category_ids = root.id.to_s
    sign_in(member)
  end

  it "loads real resources through the connector and links to the resource banner" do
    visit(root.url)
    expect(page).to have_css(".resource-library__title", text: "Resource Library")
    expect(page).to have_css(".category-node__topic-link", text: resource.topic.title)
    find(".category-node__topic-link", text: resource.topic.title).click
    expect(page).to have_css(".resource-topic-view__title", text: resource.topic.title)
    find(".resource-topic-view__back").click
    expect(page).to have_css(".category-node__topic-link", text: resource.topic.title)
  end
end
