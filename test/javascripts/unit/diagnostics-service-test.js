import { module, test } from "qunit";
import { setupRenderingTest } from "discourse/tests/helpers/component-test";
import pretender, { response } from "discourse/tests/helpers/create-pretender";

module("Unit | Moddashplugin | diagnostics queue", function (hooks) {
  setupRenderingTest(hooks);
  hooks.beforeEach(function () {
    this.siteSettings = this.owner.lookup("service:site-settings");
    this.siteSettings.moddashplugin_enabled = true;
    this.siteSettings.moddashplugin_diagnostics_enabled = true;
    this.reporter = this.owner.lookup("service:moddash-diagnostics");
    this.reporter.queue = [];
    this.reporter.persist();
  });
  hooks.afterEach(function () {
    clearTimeout(this.reporter.timer);
    this.reporter.queue = [];
    this.reporter.persist();
  });

  test("keeps a bounded technical queue and drops raw content before storage", function (assert) {
    for (let i = 0; i < 30; i++) {
      this.reporter.record({
        event: "load_failed",
        operation: "load",
        code: "network_error",
        trace_id: `reference-${i}`,
        q: "private search",
        message: "private title",
        url: "/private",
      });
    }
    assert.strictEqual(this.reporter.queue.length, 20);
    const stored = window.sessionStorage.getItem(this.reporter.storageKey);
    assert.false(stored.includes("private"));
    assert.true(
      this.reporter.queue.every((entry) => entry.event_id && entry.occurred_at)
    );
  });

  test("successful reports are delivered in a small batch and removed", async function (assert) {
    pretender.post("/moddashplugin/diagnostics.json", (request) => {
      const data = JSON.parse(request.requestBody);
      assert.strictEqual(data.events.length, 1);
      return response({}, 204);
    });
    this.reporter.record({
      event: "load_failed",
      operation: "load",
      code: "timeout",
    });
    await this.reporter.flush();
    assert.strictEqual(this.reporter.queue.length, 0);
  });

  test("a reporting outage preserves the queued event without throwing", async function (assert) {
    pretender.post("/moddashplugin/diagnostics.json", () =>
      response({ errors: ["offline"] }, 503)
    );
    this.reporter.record({
      event: "load_failed",
      operation: "load",
      code: "timeout",
    });
    await this.reporter.flush();
    assert.strictEqual(this.reporter.queue.length, 1);
    assert.strictEqual(this.reporter.readQueue().length, 1);
  });

  test("disabling diagnostics collects nothing", function (assert) {
    this.siteSettings.moddashplugin_diagnostics_enabled = false;
    this.reporter.record({
      event: "load_failed",
      operation: "load",
      code: "timeout",
    });
    assert.strictEqual(this.reporter.queue.length, 0);
  });
});
