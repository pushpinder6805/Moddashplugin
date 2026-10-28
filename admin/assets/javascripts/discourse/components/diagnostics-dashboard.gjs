import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

const REASONS = {
  ok: "Completed successfully",
  http_error: "Server returned an HTTP error",
  timeout: "Request timed out",
  network_error: "Browser could not reach the server",
  invalid_response: "Response had an unexpected format",
  pagination_stalled: "Pagination stopped advancing",
  count_changed:
    "Loaded count differs from the server snapshot; inspect retries, deletion or access changes",
  unexpected_client_error: "Unexpected JavaScript error in the plugin",
  server_exception:
    "Server raised an exception; correlate the request ID with /logs",
  not_found: "Root or resource was missing or not visible to this account",
  forbidden: "Access was denied",
  invalid_request: "Request parameters or pagination cursor were rejected",
};
function reason(code) {
  return REASONS[code] || code;
}
function stamp(value) {
  return value ? new Date(value).toLocaleString() : "—";
}

export default class DiagnosticsDashboard extends Component {
  @service dialog;

  @tracked data = null;
  @tracked filter = "";
  @tracked failuresOnly = true;
  @tracked busy = false;
  @tracked error = false;

  get state() {
    return this.data || this.args.data;
  }

  get entries() {
    const query = this.filter.toLowerCase().trim();
    return (this.state.entries || []).filter((entry) => {
      if (this.failuresOnly && entry.code === "ok") {
        return false;
      }
      return (
        !query ||
        [
          entry.username,
          entry.trace_id,
          entry.request_id,
          entry.root_id,
          entry.event,
          entry.code,
        ]
          .join(" ")
          .toLowerCase()
          .includes(query)
      );
    });
  }

  @action
  updateFilter(event) {
    this.filter = event.target.value;
  }

  @action
  toggleFailures(event) {
    this.failuresOnly = event.target.checked;
  }

  @action
  async refresh() {
    this.busy = true;
    this.error = false;
    try {
      this.data = await ajax("/moddashplugin/admin/diagnostics.json");
    } catch {
      this.error = true;
    } finally {
      this.busy = false;
    }
  }

  @action
  async clear() {
    if (
      !(await this.dialog.confirm({
        message:
          "Clear captured diagnostics? Saved resource orders and resources are unaffected.",
      }))
    ) {
      return;
    }
    try {
      await ajax("/moddashplugin/admin/diagnostics.json", { type: "DELETE" });
      await this.refresh();
    } catch {
      this.error = true;
    }
  }

  <template>
    <section class="moddash-diagnostics">
      <h2>Resource library diagnostics</h2>
      <p>Technical reports from resource loads and failures. Retains up to
        {{this.state.max_entries}}
        reports for
        {{this.state.retention_days}}
        days. Times use your browser's timezone.</p>
      <p>Reporting enabled:
        {{if this.state.enabled "Yes" "No"}}. Offline reports arrive only after
        connection is restored. A successful load can legitimately have fewer
        resources when category permissions differ.</p>
      <div class="moddash-diagnostics__controls">
        <input
          aria-label="Filter diagnostics"
          placeholder="Username, reference, request ID or root category"
          value={{this.filter}}
          {{on "input" this.updateFilter}}
        />
        <label><input
            checked={{this.failuresOnly}}
            type="checkbox"
            {{on "change" this.toggleFailures}}
          />
          Failures and retries only</label>
        <button
          class="btn btn-default"
          disabled={{this.busy}}
          type="button"
          {{on "click" this.refresh}}
        >Refresh</button>
        <button
          class="btn btn-danger"
          disabled={{this.busy}}
          type="button"
          {{on "click" this.clear}}
        >Clear reports</button>
      </div>
      {{#if this.error}}<p role="alert">Could not load diagnostics. Try Refresh.</p>{{/if}}
      <div class="moddash-diagnostics__table">
        <table>
          <thead><tr><th>Received</th><th>Account</th><th>Operation / event</th><th
              >Reason</th><th>Details</th></tr></thead>
          <tbody>
            {{#each this.entries key="id" as |entry|}}
              <tr>
                <td>{{stamp entry.received_at}}</td>
                <td>{{entry.username}} ({{entry.role}})</td>
                <td>{{entry.operation}} / {{entry.event}}</td>
                <td>{{reason entry.code}}</td>
                <td><details><summary>Root
                      {{entry.root_id}}
                      ·
                      {{entry.duration_ms}}
                      ms · HTTP
                      {{entry.status}}</summary>
                    <p>Occurred:
                      {{stamp entry.occurred_at}}<br />Reference:
                      <code>{{entry.trace_id}}</code><br />Request ID:
                      <code>{{entry.request_id}}</code><br />Topics:
                      {{entry.topics}}
                      / expected
                      {{entry.expected_topics}}
                      · Categories:
                      {{entry.categories}}
                      · Pages:
                      {{entry.pages}}
                      · Attempt:
                      {{entry.attempt}}<br />Source:
                      {{entry.source}}
                      · Server version:
                      {{entry.version}}
                      ({{entry.revision}}) · Browser version:
                      {{entry.client_version}}<br />Exception:
                      {{entry.exception_class}}
                      ·
                      {{entry.script}}:{{entry.line}}:{{entry.column}}<br
                      />Browser:
                      {{entry.browser}}
                      · Online:
                      {{entry.online}}
                      · Response:
                      {{entry.response_type}}
                      · Redirected:
                      {{entry.redirected}}</p>
                  </details></td>
              </tr>
            {{else}}<tr><td colspan="5">No matching reports. Uncheck the filter
                  to see successful loads.</td></tr>{{/each}}
          </tbody>
        </table>
      </div>
    </section>
  </template>
}
