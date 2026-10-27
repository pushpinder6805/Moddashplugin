import { module, test } from "qunit";
import {
  loadResourceLibrary,
  resourceRoots,
  sortResourceTopics,
} from "discourse/plugins/moddashplugin/discourse/lib/resource-data";

module("Unit | Moddashplugin | resource data", function () {
  test("new topics precede manual order without mutating the source", function (assert) {
    const topics = [{ id: 1 }, { id: 2 }, { id: 3 }];
    assert.deepEqual(
      sortResourceTopics(topics, [2, 1]).map((t) => t.id),
      [3, 2, 1]
    );
    assert.deepEqual(
      topics.map((t) => t.id),
      [1, 2, 3]
    );
  });

  test("root IDs come from site settings with the original tab labels", function (assert) {
    assert.deepEqual(
      resourceRoots({ moddashplugin_root_category_ids: "20|30|40" }).map(
        (root) => [root.id, root.label]
      ),
      [
        [20, "All Resources"],
        [30, "California Resources"],
        [40, "All States Resources"],
      ]
    );
  });

  test("loads all bulk pages and publishes completed pages", async function (assert) {
    const urls = [];
    const pages = [];
    await loadResourceLibrary(
      10,
      async (url) => {
        urls.push(url);
        return urls.length === 1
          ? {
              categories: [{ id: 10 }],
              topics: [{ id: 1 }],
              next_cursor: "next",
            }
          : { topics: [{ id: 2 }], next_cursor: null };
      },
      undefined,
      (page) => pages.push(page)
    );
    assert.strictEqual(pages.length, 2);
    assert.true(urls[1].includes("cursor=next"));
    assert.false(
      urls.some((url) => url.includes("/c/")),
      "no per-category topic requests"
    );
  });

  test("partial pages remain published if a later request fails", async function (assert) {
    const pages = [];
    let calls = 0;
    await assert.rejects(
      loadResourceLibrary(
        10,
        async () => {
          if (calls++) {
            throw new Error("offline");
          }
          return {
            categories: [{ id: 10 }],
            topics: [{ id: 1 }],
            next_cursor: "next",
          };
        },
        undefined,
        (page) => pages.push(page)
      ),
      /offline/
    );
    assert.strictEqual(pages[0].topics[0].id, 1);
  });

  test("rejects non-advancing cursors and malformed responses", async function (assert) {
    await assert.rejects(
      loadResourceLibrary(
        10,
        async () => ({
          categories: [{ id: 10 }],
          topics: [{ id: 1 }],
          next_cursor: "same",
        }),
        undefined,
        () => {}
      ),
      /did not advance/
    );
    await assert.rejects(
      loadResourceLibrary(
        10,
        async () => ({}),
        undefined,
        () => {}
      ),
      /Invalid/
    );
  });

  test("aborted loads never issue a request", async function (assert) {
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(
      loadResourceLibrary(
        10,
        () => assert.true(false),
        controller.signal,
        () => {}
      ),
      (error) => error.name === "AbortError"
    );
  });
});
