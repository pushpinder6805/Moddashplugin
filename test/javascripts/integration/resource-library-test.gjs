import { click, render, waitUntil } from "@ember/test-helpers";
import { module, test } from "qunit";
import sinon from "sinon";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import ResourceLibrary from "discourse/plugins/moddashplugin/discourse/components/resource-library";

module("Integration | Moddashplugin | resource library", function (hooks) {
  setupRenderingTest(hooks);

  hooks.beforeEach(function () {
    const settings = this.owner.lookup("service:site-settings");
    settings.moddashplugin_enabled = true;
    settings.moddashplugin_root_category_ids = "10|61|197";
    settings.moddashplugin_topics_per_category = 5;
    this.category = { id: 10 };
    this.fetchStub = sinon.stub(window, "fetch").callsFake(async (url) => {
      const rootId = Number(
        new URL(url, window.location.origin).searchParams.get("root_id")
      );
      return new Response(
        JSON.stringify({
          categories: [
            { id: rootId, name: "Root", slug: "root" },
            {
              id: rootId + 1,
              name: "Child category",
              slug: "child",
              parent_category_id: rootId,
            },
          ],
          topics: [
            {
              id: rootId + 1000,
              title: `Root resource ${rootId}`,
              slug: "root-resource",
              category_id: rootId,
            },
            {
              id: rootId + 2000,
              title: `Child resource ${rootId}`,
              slug: "child-resource",
              category_id: rootId + 1,
            },
          ],
          order_config: {},
          next_cursor: null,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });
  });

  hooks.afterEach(function () {
    this.fetchStub.restore();
  });

  test("renders the original tabs, root topics, children, and member controls", async function (assert) {
    await render(
      <template><ResourceLibrary @category={{this.category}} /></template>
    );

    await waitUntil(() => document.querySelector(".category-node__topic-link"));
    assert.dom(".resource-library__tab").exists({ count: 3 });
    assert.dom(".resource-library__tab").hasText("All Resources");
    assert
      .dom('.category-node__topic-link[href="/t/root-resource/1010"]')
      .hasText("Root resource 10");
    assert
      .dom('.category-node__topic-link[href="/t/child-resource/2010"]')
      .exists();
    assert.dom(".resource-library__new-btn").hasText("+ New Resource");
    assert.dom(".category-node__delete-btn").doesNotExist();
  });

  test("switching tabs loads the matching root and clears old resources", async function (assert) {
    await render(
      <template><ResourceLibrary @category={{this.category}} /></template>
    );
    await click(".resource-library__tab:nth-child(2)");
    await waitUntil(() =>
      document.querySelector(
        '.category-node__topic-link[href="/t/root-resource/1061"]'
      )
    );

    assert
      .dom(".resource-library__title")
      .hasText("California Resource Library");
    assert
      .dom('.category-node__topic-link[href="/t/root-resource/1061"]')
      .exists();
    assert
      .dom('.category-node__topic-link[href="/t/root-resource/1010"]')
      .doesNotExist();
  });
});
