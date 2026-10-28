import Service, { service } from "@ember/service";
import RSVP from "rsvp";
import { ajax } from "discourse/lib/ajax";

const FIELDS = new Set([
  "event",
  "operation",
  "code",
  "response_type",
  "redirected",
  "trace_id",
  "request_id",
  "exception_class",
  "root_id",
  "status",
  "attempt",
  "page",
  "pages",
  "topics",
  "categories",
  "expected_topics",
  "duration_ms",
  "script",
  "line",
  "column",
]);
const MAX_QUEUE = 20;
const MAX_AGE = 24 * 60 * 60 * 1000;

export default class ModdashDiagnostics extends Service {
  @service siteSettings;
  @service currentUser;
  @service appEvents;

  queue = [];
  sending = false;
  timer = null;

  init() {
    super.init(...arguments);
    this.queue = this.readQueue();
    this.onlineHandler = () => this.flush();
    window.addEventListener("online", this.onlineHandler);
    this.appEvents.on("page:changed", this, "flush");
    if (this.queue.length) {
      this.schedule();
    }
  }

  willDestroy() {
    clearTimeout(this.timer);
    window.removeEventListener("online", this.onlineHandler);
    window.removeEventListener("error", this.errorHandler, true);
    window.removeEventListener("unhandledrejection", this.rejectionHandler);
    if (this.rsvpHandler) {
      RSVP.off("error", this.rsvpHandler);
    }
    this.appEvents.off("page:changed", this, "flush");
    super.willDestroy(...arguments);
  }

  get enabled() {
    return (
      this.siteSettings.moddashplugin_enabled &&
      this.siteSettings.moddashplugin_diagnostics_enabled
    );
  }

  get storageKey() {
    return `moddashplugin-diagnostics-${this.currentUser?.id || "anonymous"}`;
  }

  installErrorCapture() {
    if (this.errorHandler) {
      return;
    }
    this.seenErrors = new WeakSet();
    const capture = (error, filename = "", line = 0, column = 0) => {
      try {
        const location = `${filename} ${error?.stack || ""}`;
        if (
          !location.includes("moddashplugin") ||
          location.includes("moddash-diagnostics")
        ) {
          return;
        }
        if (!this.enabled) {
          return;
        }
        if (error && typeof error === "object") {
          if (this.seenErrors.has(error)) {
            return;
          }
          this.seenErrors.add(error);
        }
        if (!filename) {
          const frame = error?.stack?.match(
            /([^\s()]*moddashplugin[^()\s]*\.js):(\d+):(\d+)/
          );
          if (frame) {
            filename = frame[1];
            line = Number(frame[2]);
            column = Number(frame[3]);
          }
        }
        const script = filename.split("/").pop()?.split("?")[0];
        this.record({
          event: "client_error",
          operation: "runtime",
          code: "unexpected_client_error",
          trace_id: this.traceId(),
          exception_class: error?.name || "Error",
          script,
          line,
          column,
        });
      } catch {
        /* Error reporting must never cause another uncaught error. */
      }
    };
    this.errorHandler = (event) =>
      capture(
        event.error,
        event.filename || event.target?.src,
        event.lineno,
        event.colno
      );
    this.rejectionHandler = (event) => capture(event.reason);
    this.rsvpHandler = (error) => capture(error);
    RSVP.on("error", this.rsvpHandler);
    window.addEventListener("error", this.errorHandler, true);
    window.addEventListener("unhandledrejection", this.rejectionHandler);
  }

  traceId() {
    return (
      globalThis.crypto?.randomUUID?.() ||
      `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`
    );
  }

  readQueue() {
    try {
      const stored = JSON.parse(
        window.sessionStorage.getItem(this.storageKey) || "[]"
      );
      return Array.isArray(stored)
        ? stored
            .filter((item) => item.queued_at > Date.now() - MAX_AGE)
            .slice(-MAX_QUEUE)
        : [];
    } catch {
      return [];
    }
  }

  persist() {
    try {
      window.sessionStorage.setItem(
        this.storageKey,
        JSON.stringify(this.queue)
      );
    } catch {
      // Reporting also works in memory when storage is unavailable.
    }
  }

  recordActionFailure(operation, error, rootId) {
    const xhr = error?.jqXHR || error;
    this.record({
      event: "action_failed",
      operation,
      code: xhr?.status === 0 ? "network_error" : "http_error",
      root_id: rootId,
      status: xhr?.status,
      request_id: xhr?.getResponseHeader?.("X-Request-Id"),
      trace_id: this.traceId(),
    });
  }

  record(event) {
    if (!this.enabled || this.isDestroying) {
      return;
    }
    const safe = Object.fromEntries(
      Object.entries(event).filter(
        ([key, value]) =>
          FIELDS.has(key) &&
          ["string", "number", "boolean"].includes(typeof value)
      )
    );
    this.queue.push({
      ...safe,
      event_id: this.traceId(),
      occurred_at: new Date().toISOString(),
      browser: navigator.userAgent,
      online: navigator.onLine !== false,
      client_version: "0.2.0",
      queued_at: Date.now(),
    });
    this.queue = this.queue.slice(-MAX_QUEUE);
    this.persist();
    this.schedule();
  }

  schedule(delay = 500) {
    if (this.timer || this.isDestroying) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, delay);
  }

  async flush() {
    if (
      !this.enabled ||
      this.sending ||
      !this.queue.length ||
      navigator.onLine === false
    ) {
      return;
    }
    this.queue = this.queue.filter(
      (item) => item.queued_at > Date.now() - MAX_AGE
    );
    if (!this.queue.length) {
      this.persist();
      return;
    }
    this.sending = true;
    const batch = this.queue.slice(0, 10);
    try {
      const delivery = await ajax("/moddashplugin/diagnostics.json", {
        type: "POST",
        returnXHR: true,
        contentType: "application/json",
        data: JSON.stringify({ events: batch }),
      });
      if (delivery?.xhr?.status !== 204) {
        throw new Error("Diagnostic report was not acknowledged");
      }
      // New reports may arrive while the batch is in flight.
      const sent = new Set(batch);
      this.queue = this.queue.filter((item) => !sent.has(item));
      this.persist();
    } catch {
      // Never report reporter failures recursively or interrupt the library.
    } finally {
      this.sending = false;
      if (this.queue.length) {
        this.schedule(30000);
      }
    }
  }
}
