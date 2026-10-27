/* eslint-disable no-alert -- Preserve the existing Resource-Library browser dialogs. */
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import Composer from "discourse/models/composer";
import { eq } from "discourse/truth-helpers";
import {
  loadResourceLibrary,
  requestJson,
  resourceRoots,
} from "../lib/resource-data.js";
import CategoryNode from "./category-node.gjs";

const SEARCH_DEBOUNCE_MS = 250;

function normalizeSearchText(value) {
  return String(value || "")
    .normalize("NFKC")
    .toLowerCase()
    .trim();
}

export default class ResourceLibrary extends Component {
  @service composer;
  @service router;
  @service site;
  @service store;
  @service currentUser;
  @service siteSettings;

  @tracked activeRootId = 10;
  @tracked categories = [];
  @tracked rootCategory = null;
  @tracked serverOrderConfig = {};
  @tracked topicsMap = {};
  @tracked searchQuery = "";
  @tracked searchTopicsMap = null;
  @tracked searching = false;
  @tracked loading = true;
  @tracked loadError = false;

  @tracked _orderOverride = null;
  _loadController = null;
  _loadRequestId = 0;
  _searchRequestId = 0;
  _searchTimer = null;
  _searchController = null;

  constructor() {
    super(...arguments);
    const category = this.args.category;
    if (category && this.ROOTS.some((root) => root.id === category.id)) {
      this.activeRootId = category.id;
    }
    this.activeRootId = category?.id || this.ROOTS[0]?.id;
    this.loadData();
  }

  willDestroy() {
    super.willDestroy(...arguments);
    clearTimeout(this._searchTimer);
    this._searchController?.abort();
    this._loadController?.abort();
    this._loadRequestId++;
    this._searchRequestId++;
  }

  get ROOTS() {
    return resourceRoots(this.siteSettings);
  }

  get dynamicTitle() {
    return (
      this.ROOTS.find((root) => root.id === this.activeRootId)?.title ||
      "Resource Library"
    );
  }

  get isStaffUser() {
    return (
      this.currentUser?.staff ||
      this.currentUser?.admin ||
      this.currentUser?.moderator
    );
  }

  get topicsPerCategory() {
    return this.siteSettings.moddashplugin_topics_per_category || 5;
  }

  get orderConfigMap() {
    return { ...this.serverOrderConfig, ...this._orderOverride };
  }

  get normalizedSearchQuery() {
    return normalizeSearchText(this.searchQuery);
  }

  get displayTopicsMap() {
    if (this.normalizedSearchQuery && this.searchTopicsMap) {
      return this.searchTopicsMap;
    }

    return this.topicsMap;
  }

  get allowedCategoryIds() {
    const allCategories = [...(this.site.categories || [])];
    const collect = (nodes) =>
      nodes.forEach((node) => {
        if (!allCategories.some((cat) => cat.id === node.id)) {
          allCategories.push(node);
        }
        collect(node.subcategories || []);
      });
    collect(this.categories);
    const allowed = [];
    const collectDescendants = (parentId) => {
      const children = allCategories.filter(
        (c) => this.getParentId(c) === parentId
      );
      children.forEach((child) => {
        allowed.push(child.id);
        collectDescendants(child.id);
      });
    };
    this.ROOTS.forEach((root) => collectDescendants(root.id));
    return allowed;
  }

  get filteredCategories() {
    let categories = this.categories;
    if (this.rootCategory && this.displayTopicsMap[this.activeRootId]?.length) {
      categories = [{ ...this.rootCategory, subcategories: [] }, ...categories];
    }
    const query = this.normalizedSearchQuery;
    return query
      ? this.filterTree(categories, this.displayTopicsMap)
      : categories;
  }

  getParentId(category) {
    return category.parent_category_id ?? category.parentCategory?.id ?? null;
  }

  requestJson(url, signal) {
    return requestJson(getURL(url), signal);
  }

  getCategoryPosition(category) {
    const position = Number(category?.position);
    return Number.isFinite(position) ? position : null;
  }

  compareCategoriesByDiscourseOrder(categoryOrder, a, b) {
    const positionA = this.getCategoryPosition(a);
    const positionB = this.getCategoryPosition(b);

    if (positionA !== null && positionB !== null && positionA !== positionB) {
      return positionA - positionB;
    }

    if (positionA !== null && positionB === null) {
      return -1;
    }

    if (positionA === null && positionB !== null) {
      return 1;
    }

    return (categoryOrder.get(a.id) ?? 0) - (categoryOrder.get(b.id) ?? 0);
  }

  buildCategoryTree(rootId, allCategories) {
    const categoriesById = new Map();
    const categoryOrder = new Map();
    const childrenByParentId = {};

    allCategories.forEach((category, index) => {
      if (!category?.id) {
        return;
      }

      categoriesById.set(category.id, category);
      categoryOrder.set(category.id, index);
      const parentId = this.getParentId(category);
      if (parentId) {
        if (!childrenByParentId[parentId]) {
          childrenByParentId[parentId] = [];
        }
        childrenByParentId[parentId].push(category);
      }
    });

    const wrap = (cat) => {
      const parentId = this.getParentId(cat);
      const parent = parentId ? categoriesById.get(parentId) : null;
      return {
        id: cat.id,
        name: cat.name,
        slug: cat.slug,
        color: cat.color,
        text_color: cat.text_color,
        description: cat.description,
        topic_count: cat.topic_count,
        topic_url: cat.topic_url,
        parent_category_id: parentId,
        parent_slug: parent?.slug,
      };
    };

    const buildChildren = (parentId, ancestors = new Set()) => {
      if (ancestors.has(parentId)) {
        return [];
      }
      const path = new Set([...ancestors, parentId]);
      return [...(childrenByParentId[parentId] || [])]
        .sort((a, b) =>
          this.compareCategoriesByDiscourseOrder(categoryOrder, a, b)
        )
        .map((category) => ({
          ...wrap(category),
          subcategories: buildChildren(category.id, path),
        }));
    };

    return buildChildren(rootId);
  }

  async loadData() {
    this._loadController?.abort();
    const controller = new AbortController();
    this._loadController = controller;
    const requestId = ++this._loadRequestId;
    const rootId = this.activeRootId;
    this.loadError = false;
    this.loading = true;
    const map = {};

    try {
      await loadResourceLibrary(
        rootId,
        (url, signal) => this.requestJson(url, signal),
        controller.signal,
        (page, first) => {
          if (requestId !== this._loadRequestId || controller.signal.aborted) {
            return;
          }
          if (first) {
            this.rootCategory = page.categories.find(
              (cat) => cat.id === rootId
            );
            this.categories = this.buildCategoryTree(rootId, page.categories);
            this.serverOrderConfig = page.order_config || {};
          }
          for (const topic of page.topics) {
            map[topic.category_id] ||= new Map();
            map[topic.category_id].set(topic.id, topic);
          }
          const loaded = Object.fromEntries(
            Object.entries(map).map(([id, topics]) => [
              id,
              [...topics.values()],
            ])
          );
          // During Retry, retain pages already visible until replacement completes.
          this.topicsMap = {
            ...this.topicsMap,
            ...Object.fromEntries(
              Object.entries(loaded).map(([id, topics]) => [
                id,
                [
                  ...new Map(
                    [...(this.topicsMap[id] || []), ...topics].map((topic) => [
                      topic.id,
                      topic,
                    ])
                  ).values(),
                ],
              ])
            ),
          };
        }
      );
      if (requestId === this._loadRequestId) {
        this.topicsMap = Object.fromEntries(
          Object.entries(map).map(([id, topics]) => [id, [...topics.values()]])
        );
      }
    } catch (error) {
      if (requestId === this._loadRequestId && !controller.signal.aborted) {
        this.loadError = true;
        // eslint-disable-next-line no-console
        console.error("ResourceLibrary: failed to load", error);
      }
    } finally {
      if (requestId === this._loadRequestId) {
        this.loading = false;
      }
    }
  }

  @action
  retryLoad() {
    this.loadData();
  }

  async searchResourceTopics(query, rootId, signal) {
    const map = {};
    await loadResourceLibrary(
      rootId,
      (url, requestSignal) => this.requestJson(url, requestSignal),
      signal,
      (page) => {
        for (const topic of page.topics) {
          map[topic.category_id] ||= [];
          map[topic.category_id].push(topic);
        }
      },
      query
    );
    return map;
  }

  getLocalSearchTopics(query) {
    const map = {};

    Object.entries(this.topicsMap).forEach(([categoryId, topics]) => {
      const matches = topics.filter((topic) =>
        normalizeSearchText(topic.title).includes(query)
      );
      if (matches.length > 0) {
        map[categoryId] = matches;
      }
    });

    return map;
  }

  @action
  switchRoot(root) {
    clearTimeout(this._searchTimer);
    this._searchController?.abort();
    this._searchRequestId++;
    this.activeRootId = root.id;
    this.topicsMap = {};
    this.categories = [];
    this.rootCategory = null;
    this._orderOverride = null;
    this.searchQuery = "";
    this.searchTopicsMap = null;
    this.searching = false;
    this.loadData();
  }

  @action
  onSearchInput(e) {
    this.searchQuery = e.target.value;
    const query = this.normalizedSearchQuery;
    const requestId = ++this._searchRequestId;

    clearTimeout(this._searchTimer);
    this._searchController?.abort();

    if (!query) {
      this.searchTopicsMap = null;
      this.searching = false;
      return;
    }

    const rootId = this.activeRootId;
    this.searching = true;
    const controller = new AbortController();
    this._searchController = controller;

    this._searchTimer = setTimeout(async () => {
      try {
        const map = await this.searchResourceTopics(
          query,
          rootId,
          controller.signal
        );
        if (
          requestId === this._searchRequestId &&
          rootId === this.activeRootId
        ) {
          this.searchTopicsMap = map;
        }
      } catch {
        // Keep local search available if native Discourse search is unavailable.
        if (requestId === this._searchRequestId && !controller.signal.aborted) {
          this.searchTopicsMap = this.getLocalSearchTopics(query);
        }
      } finally {
        if (requestId === this._searchRequestId) {
          this.searching = false;
        }
      }
    }, SEARCH_DEBOUNCE_MS);
  }

  @action
  openNewResource() {
    const allowedIds = this.allowedCategoryIds;
    const styleId = "resource-library-composer-filter";
    let styleEl = document.getElementById(styleId);
    if (!styleEl) {
      styleEl = document.createElement("style");
      styleEl.id = styleId;
      document.head.appendChild(styleEl);
    }

    if (allowedIds.length > 0) {
      const allowSelectors = allowedIds
        .map((id) => `.category-chooser .category-row[data-value="${id}"]`)
        .join(",\n");
      styleEl.textContent = `.category-chooser .category-row { display: none !important; }\n${allowSelectors} { display: flex !important; }`;
    } else {
      styleEl.textContent = "";
    }

    this.composer.open({
      action: Composer.CREATE_TOPIC,
      draftKey: Composer.CREATE_TOPIC,
      draftSequence: 0,
    });

    this._watchComposerClose();
  }

  filterTree(cats, topicsMap) {
    return cats
      .map((cat) => {
        const filteredSubs = cat.subcategories
          ? this.filterTree(cat.subcategories, topicsMap)
          : [];

        const matchingTopics = topicsMap[cat.id] || [];

        if (filteredSubs.length > 0 || matchingTopics.length > 0) {
          return {
            ...cat,
            subcategories: filteredSubs,
            _filteredTopics: matchingTopics,
          };
        }
        return null;
      })
      .filter(Boolean);
  }

  @action
  async editTopic(topic) {
    try {
      const result = await ajax(`/t/${topic.id}.json`);
      const post = result.post_stream?.posts?.[0];
      if (!post) {
        alert("Could not load topic content.");
        return;
      }

      this.composer.open({
        action: Composer.EDIT,
        topic: this.store.createRecord("topic", result),
        post: this.store.createRecord("post", post),
        draftKey: `topic_${topic.id}`,
        draftSequence: 0,
      });
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("Failed to open topic for editing", e);
      alert("Failed to open topic for editing. Please try again.");
    }
  }

  @action
  async deleteTopic(topic) {
    if (
      !confirm(`Are you sure you want to permanently delete "${topic.title}"?`)
    ) {
      return;
    }

    try {
      await ajax(`/t/${topic.id}`, { type: "DELETE" });
      const newMap = { ...this.topicsMap };
      Object.keys(newMap).forEach((catId) => {
        newMap[catId] = newMap[catId].filter((t) => t.id !== topic.id);
      });
      this.topicsMap = newMap;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("Failed to delete topic", e);
      alert("Failed to delete topic. Please try again.");
    }
  }

  @action
  updateOrderConfig(categoryId, orderedIds) {
    const current = this.orderConfigMap;
    const newMap = { ...current };
    newMap[categoryId] = { orderedIds };
    this._orderOverride = newMap;
  }

  @action
  openNewCategory() {
    this.router.transitionTo("newCategory");
  }

  _watchComposerClose() {
    const styleId = "resource-library-composer-filter";
    const check = () => {
      const composerEl = document.getElementById("reply-control");
      const isClosed = !composerEl || composerEl.classList.contains("closed");
      if (isClosed) {
        const el = document.getElementById(styleId);
        if (el) {
          el.remove();
        }
      } else {
        requestAnimationFrame(check);
      }
    };
    requestAnimationFrame(check);
  }

  <template>
    <div class="resource-library">
      <div class="resource-library__header">
        <h1 class="resource-library__title">{{this.dynamicTitle}}</h1>
        <p class="resource-library__description">
          Check back here regularly for new resources and if there's something
          you think would be helpful to include, please let us know (send it to
          <a href="mailto:MASH@healthlaw.org">MASH@healthlaw.org</a>)!
        </p>
      </div>

      <div class="resource-library__controls">
        <div class="resource-library__tabs">
          {{#each this.ROOTS as |root|}}
            <button
              class="resource-library__tab
                {{if
                  (eq root.id this.activeRootId)
                  'resource-library__tab--active'
                }}"
              type="button"
              {{on "click" (fn this.switchRoot root)}}
            >
              {{root.label}}
            </button>
          {{/each}}
        </div>

        <div class="resource-library__actions">
          <div class="resource-library__search">
            <input
              class="resource-library__search-input"
              disabled={{this.loading}}
              placeholder="Search resources..."
              type="text"
              value={{this.searchQuery}}
              {{on "input" this.onSearchInput}}
            />
          </div>

          {{#if this.isStaffUser}}
            <button
              class="resource-library__manage-btn btn btn-icon btn-default"
              title="New Category"
              type="button"
              {{on "click" this.openNewCategory}}
            >
              <svg
                class="fa d-icon d-icon-wrench svg-icon"
                height="14"
                viewBox="0 0 512 512"
                width="14"
                xmlns="http://www.w3.org/2000/svg"
              ><path
                  d="M352 320c88.4 0 160-71.6 160-160c0-15.3-2.2-30.1-6.2-44.2c-3.1-10.8-16.4-13.2-24.3-5.3l-76.8 76.8c-3 3-7.1 4.7-11.3 4.7H336c-8.8 0-16-7.2-16-16V118.6c0-4.2 1.7-8.3 4.7-11.3l76.8-76.8c7.9-7.9 5.4-21.2-5.3-24.3C382.1 2.2 367.3 0 352 0C263.6 0 192 71.6 192 160c0 19.1 3.4 37.5 9.5 54.5L19.9 396.1C7.2 408.8 0 426.1 0 444.1C0 481.6 30.4 512 67.9 512c18 0 35.3-7.2 48-19.9l181.6-181.6c17 6.2 35.4 9.5 54.5 9.5zM80 456c-13.3 0-24-10.7-24-24s10.7-24 24-24s24 10.7 24 24s-10.7 24-24 24z"
                  fill="currentColor"
                /></svg>
            </button>
          {{/if}}

          <button
            class="resource-library__new-btn"
            type="button"
            {{on "click" this.openNewResource}}
          >
            + New Resource
          </button>
        </div>
      </div>

      <div class="resource-library__content">
        {{#if this.loadError}}
          <div class="resource-library__error" role="alert">
            Some resources could not be loaded. Please try again.
            <button
              class="btn btn-default"
              disabled={{this.loading}}
              type="button"
              {{on "click" this.retryLoad}}
            >Retry</button>
          </div>
        {{/if}}
        {{#if this.loading}}
          <div class="resource-library__loading" role="status">Loading
            resources...</div>
        {{/if}}
        {{#if this.searching}}
          <div class="resource-library__loading">Searching resources...</div>
        {{else if this.filteredCategories.length}}
          {{#each this.filteredCategories as |cat|}}
            <CategoryNode
              @category={{cat}}
              @isStaff={{this.isStaffUser}}
              @maxTopics={{this.topicsPerCategory}}
              @onDeleteTopic={{this.deleteTopic}}
              @onEditTopic={{this.editTopic}}
              @onOrderSaved={{this.updateOrderConfig}}
              @orderConfigMap={{this.orderConfigMap}}
              @rootId={{this.activeRootId}}
              @searchQuery={{this.normalizedSearchQuery}}
              @topicsMap={{this.displayTopicsMap}}
            />
          {{/each}}
        {{else}}
          {{#unless this.loading}}
            {{#unless this.loadError}}
              <div class="resource-library__empty">No resources found.</div>
            {{/unless}}
          {{/unless}}
        {{/if}}
      </div>
    </div>
  </template>
}
