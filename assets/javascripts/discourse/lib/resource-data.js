function emitDiagnostic(context, event) {
  try {
    context.onEvent?.(event);
  } catch {
    /* A reporter must never affect loading. */
  }
}

const RETRIES = 2;
const TIMEOUT_MS = 15000;

export function abortError() {
  return new DOMException("Resource loading cancelled", "AbortError");
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      return reject(abortError());
    }
    const cancel = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", cancel);
      resolve();
    }, ms);
    signal?.addEventListener("abort", cancel, { once: true });
  });
}

export async function requestJson(url, signal, context = {}) {
  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) {
      throw abortError();
    }
    const controller = new AbortController();
    const cancel = () => controller.abort();
    signal?.addEventListener("abort", cancel, { once: true });
    const timer = setTimeout(cancel, TIMEOUT_MS);
    const started = Date.now();
    let requestId = null;
    let retryDelay = 1000 * 2 ** attempt;
    try {
      const response = await fetch(url, {
        credentials: "same-origin",
        headers: {
          accept: "application/json",
          "X-Requested-With": "XMLHttpRequest",
          ...(context.traceId ? { "X-Moddash-Trace-ID": context.traceId } : {}),
        },
        signal: controller.signal,
      });
      requestId = response.headers.get("X-Request-Id");
      if (!response.ok) {
        const error = new Error(`Resource request failed: ${response.status}`);
        error.status = response.status;
        error.code = "http_error";
        error.retryable = response.status === 429 || response.status >= 500;
        const retryAfter = response.headers.get("Retry-After");
        if (retryAfter) {
          const seconds = Number(retryAfter);
          retryDelay = Math.max(
            retryDelay,
            Number.isFinite(seconds)
              ? seconds * 1000
              : Date.parse(retryAfter) - Date.now() || 0
          );
        }
        throw error;
      }
      let result;
      try {
        result = await response.json();
      } catch (cause) {
        const error = new Error("Invalid resource response", { cause });
        error.code = controller.signal.aborted ? "timeout" : "invalid_response";
        error.status = response.status;
        error.responseType = response.headers
          .get("Content-Type")
          ?.includes("text/html")
          ? "html"
          : response.headers.get("Content-Type")?.includes("json")
            ? "json"
            : "other";
        error.redirected = response.redirected;
        throw error;
      }
      if (attempt > 0) {
        emitDiagnostic(context, {
          event: "request_recovered",
          code: "ok",
          attempt: attempt + 1,
          request_id: requestId,
          duration_ms: Date.now() - started,
        });
      }
      return result;
    } catch (cause) {
      if (signal?.aborted) {
        throw abortError();
      }
      // DOMException.code is read-only and numeric. Keep our diagnostic code on
      // a normal Error, including when fetch is aborted by the timeout.
      const error = Object.assign(
        new Error(cause.message || "Resource request failed", { cause }),
        {
          code: controller.signal.aborted
            ? "timeout"
            : typeof cause.code === "string"
              ? cause.code
              : "network_error",
          status: cause.status,
          responseType: cause.responseType,
          redirected: cause.redirected,
          retryable: cause.retryable,
        }
      );
      error.requestId = requestId;
      error.attempt = attempt + 1;
      if (error.retryable === false || attempt >= RETRIES) {
        throw error;
      }
      emitDiagnostic(context, {
        event: "request_retry",
        code: error.code,
        status: error.status,
        response_type: error.responseType,
        redirected: error.redirected,
        attempt: attempt + 1,
        request_id: requestId,
        duration_ms: Date.now() - started,
      });
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
    }
    await wait(retryDelay, signal);
  }
}

export function flattenCategories(categories) {
  const result = new Map();
  const visit = (category, parentId) => {
    if (!category?.id) {
      return;
    }
    result.set(
      category.id,
      parentId && !category.parent_category_id
        ? { ...category, parent_category_id: parentId }
        : category
    );
    (category.subcategory_list || []).forEach((child) =>
      visit(child, category.id)
    );
  };
  categories.forEach((category) => visit(category));
  return [...result.values()];
}

export function sortResourceTopics(topics, orderedIds = []) {
  const positions = new Map(
    (orderedIds || []).map((id, index) => [Number(id), index])
  );
  return [...topics].sort((a, b) => {
    const aPosition = positions.get(Number(a.id));
    const bPosition = positions.get(Number(b.id));
    if (aPosition !== undefined && bPosition !== undefined) {
      return aPosition - bPosition;
    }
    if (aPosition !== undefined) {
      return 1;
    }
    if (bPosition !== undefined) {
      return -1;
    }
    const dateA = Date.parse(a.created_at) || 0;
    const dateB = Date.parse(b.created_at) || 0;
    return dateB - dateA || Number(b.id) - Number(a.id);
  });
}

export function resourceRoots(siteSettings) {
  const labels = [
    { label: "All Resources", title: "Resource Library" },
    { label: "California Resources", title: "California Resource Library" },
    { label: "All States Resources", title: "All States Resource Library" },
  ];
  return String(siteSettings.moddashplugin_root_category_ids ?? "10|61|197")
    .split("|")
    .map(Number)
    .filter((id) => Number.isSafeInteger(id) && id > 0)
    .map((id, index) => ({
      id,
      ...(labels[index] || { label: "Resources", title: "Resource Library" }),
    }));
}

export async function loadResourceLibrary(
  rootId,
  request,
  signal,
  onPage,
  query = ""
) {
  const cursors = new Set();
  let cursor = null;
  let first = true;
  do {
    if (signal?.aborted) {
      throw abortError();
    }
    const params = new URLSearchParams({ root_id: rootId });
    if (query) {
      params.set("q", query);
    }
    if (cursor) {
      params.set("cursor", cursor);
    }
    const result = await request(
      `/moddashplugin/library.json?${params}`,
      signal
    );
    if (
      !Array.isArray(result.topics) ||
      (first && !Array.isArray(result.categories))
    ) {
      throw Object.assign(new Error("Invalid resource library response"), {
        code: "invalid_response",
      });
    }
    if (
      first &&
      !result.categories.some(
        (category) => Number(category.id) === Number(rootId)
      )
    ) {
      throw Object.assign(
        new Error("Resource root is missing from the library response"),
        { code: "invalid_response" }
      );
    }
    if (result.next_cursor != null && typeof result.next_cursor !== "string") {
      throw Object.assign(new Error("Invalid resource cursor"), {
        code: "invalid_response",
      });
    }
    onPage(result, first);
    first = false;
    cursor = result.next_cursor;
    if (cursor) {
      if (cursors.has(cursor) || result.topics.length === 0) {
        throw Object.assign(new Error("Resource pagination did not advance"), {
          code: "pagination_stalled",
        });
      }
      cursors.add(cursor);
    }
  } while (cursor);
}
