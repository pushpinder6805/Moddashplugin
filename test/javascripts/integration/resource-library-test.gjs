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
    settings.moddashplugin_diagnostics_enabled = false;
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
  test("failed loads show Retry and recover without a page reload", async function (assert) {
    this.fetchStub
      .onFirstCall()
      .resolves(new Response("forbidden", { status: 403 }));
    await render(
      <template><ResourceLibrary @category={{this.category}} /></template>
    );
    await waitUntil(() => document.querySelector(".resource-library__error"));
    assert.dom(".resource-library__error button").hasText("Retry");
    await click(".resource-library__error button");
    await waitUntil(() => document.querySelector(".category-node__topic-link"));
    assert.dom(".resource-library__error").doesNotExist();
    assert
      .dom('.category-node__topic-link[href="/t/root-resource/1010"]')
      .exists();
  });

  test("a late response from the old tab cannot replace the selected tab", async function (assert) {
    let finishOld;
    this.fetchStub.onFirstCall().returns(
      new Promise((resolve) => {
        finishOld = resolve;
      })
    );
    await render(
      <template><ResourceLibrary @category={{this.category}} /></template>
    );
    await click(".resource-library__tab:nth-child(2)");
    await waitUntil(() =>
      document.querySelector(
        '.category-node__topic-link[href="/t/root-resource/1061"]'
      )
    );
    finishOld(
      new Response(
        JSON.stringify({
          categories: [{ id: 10 }],
          topics: [
            {
              id: 999,
              category_id: 10,
              title: "Stale resource",
              slug: "stale",
            },
          ],
          next_cursor: null,
        }),
        { status: 200 }
      )
    );
    await waitUntil(() => this.fetchStub.callCount === 2);
    assert
      .dom(".resource-library__title")
      .hasText("California Resource Library");
    assert
      .dom('.category-node__topic-link[href="/t/root-resource/1061"]')
      .exists();
    assert
      .dom('.category-node__topic-link[href="/t/stale/999"]')
      .doesNotExist();
  });

  test("See more and Show less preserve the configured per-category limit", async function (assert) {
    this.fetchStub.onFirstCall().resolves(
      new Response(
        JSON.stringify({
          categories: [
            { id: 10, name: "Root", slug: "root" },
            { id: 11, name: "Child", slug: "child", parent_category_id: 10 },
          ],
          topics: Array.from({ length: 8 }, (_, index) => ({
            id: index + 1,
            category_id: 11,
            title: `Resource ${index + 1}`,
            slug: `resource-${index + 1}`,
          })),
          order_config: {},
          next_cursor: null,
        }),
        { status: 200 }
      )
    );
    await render(
      <template><ResourceLibrary @category={{this.category}} /></template>
    );
    await waitUntil(() => document.querySelector(".category-node__see-more"));
    assert.dom(".category-node__topic-link").exists({ count: 5 });
    assert.dom(".category-node__see-more").hasText("See more (3)");
    await click(".category-node__see-more");
    assert.dom(".category-node__topic-link").exists({ count: 8 });
    await click(".category-node__see-more");
    assert.dom(".category-node__topic-link").exists({ count: 5 });
  });
});
