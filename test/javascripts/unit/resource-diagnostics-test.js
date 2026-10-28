import { module, test } from "qunit";
import sinon from "sinon";
import { requestJson } from "discourse/plugins/moddashplugin/discourse/lib/resource-data";

module("Unit | Moddashplugin | request diagnostics", function (hooks) {
  hooks.afterEach(function () {
    this.fetchStub?.restore();
    this.clock?.restore();
  });

  test("retries and recovery share safe context and the response request ID", async function (assert) {
    const events = [];
    this.fetchStub = sinon.stub(window, "fetch");
    this.fetchStub.onFirstCall().resolves(
      new Response("busy", {
        status: 503,
        headers: { "X-Request-Id": "server-first" },
      })
    );
    this.fetchStub.onSecondCall().resolves(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "X-Request-Id": "server-recovered" },
      })
    );
    const result = await requestJson(
      "/moddashplugin/library.json?q=private",
      undefined,
      { traceId: "reference-12345", onEvent: (event) => events.push(event) }
    );
    assert.true(result.ok);
    assert.strictEqual(
      this.fetchStub.firstCall.args[1].headers["X-Moddash-Trace-ID"],
      "reference-12345"
    );
    assert.deepEqual(
      events.map((event) => event.event),
      ["request_retry", "request_recovered"]
    );
    assert.strictEqual(events[0].request_id, "server-first");
    assert.strictEqual(events[1].request_id, "server-recovered");
    assert.false(JSON.stringify(events).includes("private"));
  });

  test("a broken diagnostic callback cannot break a recovered request", async function (assert) {
    this.fetchStub = sinon.stub(window, "fetch");
    this.fetchStub
      .onFirstCall()
      .resolves(new Response("busy", { status: 503 }));
    this.fetchStub
      .onSecondCall()
      .resolves(new Response(JSON.stringify({ ok: true }), { status: 200 }));
    const result = await requestJson("/test", undefined, {
      onEvent: () => {
        throw new Error("reporter unavailable");
      },
    });
    assert.true(result.ok);
  });

  test("ordinary navigation cancellation is not reported as a failure", async function (assert) {
    const controller = new AbortController();
    controller.abort();
    const events = [];
    await assert.rejects(
      requestJson("/test", controller.signal, {
        onEvent: (event) => events.push(event),
      }),
      (error) => error.name === "AbortError"
    );
    assert.strictEqual(events.length, 0);
  });
  test("timeouts report a stable timeout code even when fetch throws DOMException", async function (assert) {
    this.clock = sinon.useFakeTimers({
      toFake: ["setTimeout", "clearTimeout"],
    });
    this.fetchStub = sinon.stub(window, "fetch").callsFake(
      (_url, options) =>
        new Promise((_resolve, reject) => {
          options.signal.addEventListener(
            "abort",
            () => reject(new DOMException("Request aborted", "AbortError")),
            { once: true }
          );
        })
    );
    const events = [];
    const pending = requestJson("/test", undefined, {
      onEvent: (event) => events.push(event),
    });
    const rejected = assert.rejects(
      pending,
      (error) => error.code === "timeout" && error.attempt === 3
    );
    await this.clock.tickAsync(60000);
    await rejected;
    assert.deepEqual(
      events.map((event) => event.code),
      ["timeout", "timeout"]
    );
  });
});
