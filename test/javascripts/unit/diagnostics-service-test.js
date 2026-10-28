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
      return response(204, {});
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
      response(503, { errors: ["offline"] })
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
  test("a successful HTML response is not mistaken for accepted delivery", async function (assert) {
    pretender.post("/moddashplugin/diagnostics.json", () => [
      200,
      { "Content-Type": "text/html" },
      "<html>Sign in</html>",
    ]);
    this.reporter.record({
      event: "load_failed",
      operation: "load",
      code: "timeout",
    });
    await this.reporter.flush();
    assert.strictEqual(this.reporter.queue.length, 1);
  });

  test("action failures preserve the server request ID and distinguish network failures", function (assert) {
    this.reporter.recordActionFailure(
      "reorder",
      { jqXHR: { status: 403, getResponseHeader: () => "server-request-123" } },
      10
    );
    assert.strictEqual(this.reporter.queue[0].request_id, "server-request-123");
    assert.strictEqual(this.reporter.queue[0].status, 403);
    this.reporter.recordActionFailure("edit", { jqXHR: { status: 0 } }, 10);
    assert.strictEqual(this.reporter.queue[1].code, "network_error");
  });
  test("captures plugin RSVP errors once without recording raw messages or stacks", function (assert) {
    this.reporter.installErrorCapture();
    const error = new TypeError("private resource details");
    error.stack =
      "TypeError: private resource details\n at render (https://example.invalid/assets/plugins/moddashplugin-abcd.js:12:34)";
    this.reporter.rsvpHandler(error);
    this.reporter.rsvpHandler(error);
    assert.strictEqual(this.reporter.queue.length, 1);
    assert.strictEqual(this.reporter.queue[0].exception_class, "TypeError");
    assert.strictEqual(this.reporter.queue[0].line, 12);
    assert.false(
      JSON.stringify(this.reporter.queue).includes("private resource details")
    );
    assert.false(
      JSON.stringify(this.reporter.queue).includes("example.invalid")
    );
  });
});
