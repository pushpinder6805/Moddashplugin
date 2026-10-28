/* eslint-disable no-alert -- Preserve the existing Resource-Library browser dialogs. */
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { eq } from "discourse/truth-helpers";
import { sortResourceTopics } from "../lib/resource-data.js";

function positionLabel(index) {
  return `${index + 1}.`;
}

export default class CategoryNode extends Component {
  @service("moddash-diagnostics") diagnostics;

  @tracked showAll = false;
  @tracked reorderMode = false;
  @tracked localOrderedIds = null;
  @tracked savingOrder = false;

  get topics() {
    const map = this.args.topicsMap || {};
    return map[this.args.category.id] || [];
  }

  get orderConfig() {
    const map = this.args.orderConfigMap || {};
    return map[this.args.category.id] || null;
  }

  get orderedTopicIds() {
    if (this.localOrderedIds) {
      return this.localOrderedIds;
    }
    return this.orderConfig?.orderedIds || null;
  }

  get sortedTopics() {
    return sortResourceTopics(this.topics, this.orderedTopicIds);
  }

  get filteredTopics() {
    return this.sortedTopics;
  }

  get visibleTopics() {
    const topics = this.filteredTopics;
    const query = this.args.searchQuery?.toLowerCase();
    if (query || this.showAll || this.reorderMode) {
      return topics;
    }
    const max = this.args.maxTopics || 5;
    return topics.slice(0, max);
  }

  get hasMore() {
    if (this.args.searchQuery?.trim() || this.reorderMode) {
      return false;
    }
    const max = this.args.maxTopics || 5;
    return this.filteredTopics.length > max;
  }

  get remainingCount() {
    const max = this.args.maxTopics || 5;
    return this.filteredTopics.length - max;
  }

  get subcategories() {
    return this.args.category.subcategories || [];
  }

  get hasSubcategories() {
    return this.subcategories.length > 0;
  }

  get hasTopics() {
    return this.topics.length > 0;
  }

  get canReorder() {
    return this.args.isStaff && this.topics.length > 1;
  }

  @action
  toggleShowAll() {
    this.showAll = !this.showAll;
  }

  @action
  enterReorderMode() {
    this.localOrderedIds = this.sortedTopics.map((t) => t.id);
    this.reorderMode = true;
  }

  @action
  cancelReorder() {
    this.localOrderedIds = null;
    this.reorderMode = false;
  }

  @action
  moveUp(topic) {
    const ids = [...(this.localOrderedIds || [])];
    const idx = ids.indexOf(topic.id);
    if (idx <= 0) {
      return;
    }
    [ids[idx - 1], ids[idx]] = [ids[idx], ids[idx - 1]];
    this.localOrderedIds = ids;
  }

  @action
  moveDown(topic) {
    const ids = [...(this.localOrderedIds || [])];
    const idx = ids.indexOf(topic.id);
    if (idx < 0 || idx >= ids.length - 1) {
      return;
    }
    [ids[idx], ids[idx + 1]] = [ids[idx + 1], ids[idx]];
    this.localOrderedIds = ids;
  }

  @action
  async saveOrder() {
    this.savingOrder = true;
    try {
      const ids = this.localOrderedIds || [];
      const catId = this.args.category.id;

      await ajax(`/moddashplugin/categories/${catId}/order.json`, {
        type: "PUT",
        contentType: "application/json",
        data: JSON.stringify({ root_id: this.args.rootId, ordered_ids: ids }),
      });

      if (this.args.onOrderSaved) {
        this.args.onOrderSaved(catId, ids);
      }

      this.reorderMode = false;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("Failed to save topic order", e);
      this.diagnostics.recordActionFailure("reorder", e, this.args.rootId);
      alert("Failed to save topic order. Please try again.");
    } finally {
      this.savingOrder = false;
    }
  }

  <template>
    <div class="category-node">
      <div class="category-node__header">
        <h2 class="category-node__name">{{@category.name}}</h2>
        {{#if this.canReorder}}
          {{#unless this.reorderMode}}
            <button
              class="category-node__reorder-btn"
              title="Reorder topics"
              type="button"
              {{on "click" this.enterReorderMode}}
            >
              <svg
                height="12"
                viewBox="0 0 320 512"
                width="12"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  d="M137.4 41.4c12.5-12.5 32.8-12.5 45.3 0l128 128c9.2 9.2 11.9 22.9 6.9 34.9s-16.6 19.8-29.6 19.8H32c-12.9 0-24.6-7.8-29.6-19.8s-2.2-25.7 6.9-34.9l128-128zm0 429.3l-128-128c-9.2-9.2-11.9-22.9-6.9-34.9s16.6-19.8 29.6-19.8H288c12.9 0 24.6 7.8 29.6 19.8s2.2 25.7-6.9 34.9l-128 128c-12.5 12.5-32.8 12.5-45.3 0z"
                  fill="currentColor"
                />
              </svg>
            </button>
          {{/unless}}
        {{/if}}
      </div>

      {{#if this.hasSubcategories}}
        <div class="category-node__children">
          {{#each this.subcategories as |subCat|}}
            <CategoryNode
              @category={{subCat}}
              @isStaff={{@isStaff}}
              @maxTopics={{@maxTopics}}
              @onDeleteTopic={{@onDeleteTopic}}
              @onEditTopic={{@onEditTopic}}
              @onOrderSaved={{@onOrderSaved}}
              @orderConfigMap={{@orderConfigMap}}
              @rootId={{@rootId}}
              @searchQuery={{@searchQuery}}
              @topicsMap={{@topicsMap}}
            />
          {{/each}}
        </div>
      {{/if}}

      {{#if this.hasTopics}}
        {{#if this.reorderMode}}
          <div class="category-node__reorder-bar">
            <span class="category-node__reorder-label">Reorder mode</span>
            <button
              class="category-node__reorder-save"
              disabled={{this.savingOrder}}
              type="button"
              {{on "click" this.saveOrder}}
            >
              {{if this.savingOrder "Saving..." "Save Order"}}
            </button>
            <button
              class="category-node__reorder-cancel"
              type="button"
              {{on "click" this.cancelReorder}}
            >
              Cancel
            </button>
          </div>
        {{/if}}

        {{#if this.visibleTopics.length}}
          <ul
            class="category-node__topics
              {{if this.reorderMode 'category-node__topics--reorder'}}"
          >
            {{#each this.visibleTopics as |topic index|}}
              <li
                class="category-node__topic
                  {{if this.reorderMode 'category-node__topic--reorder'}}"
              >
                {{#if this.reorderMode}}
                  <div class="category-node__reorder-controls">
                    <button
                      class="category-node__move-btn category-node__move-btn--up
                        {{if (eq index 0) 'category-node__move-btn--disabled'}}"
                      title="Move up"
                      type="button"
                      {{on "click" (fn this.moveUp topic)}}
                    >
                      <svg
                        height="10"
                        viewBox="0 0 384 512"
                        width="10"
                        xmlns="http://www.w3.org/2000/svg"
                      >
                        <path
                          d="M214.6 41.4c-12.5-12.5-32.8-12.5-45.3 0l-160 160c-12.5 12.5-12.5 32.8 0 45.3s32.8 12.5 45.3 0L160 141.2V448c0 17.7 14.3 32 32 32s32-14.3 32-32V141.2l105.4 105.4c12.5 12.5 32.8 12.5 45.3 0s12.5-32.8 0-45.3l-160-160z"
                          fill="currentColor"
                        />
                      </svg>
                    </button>
                    <button
                      class="category-node__move-btn category-node__move-btn--down"
                      title="Move down"
                      type="button"
                      {{on "click" (fn this.moveDown topic)}}
                    >
                      <svg
                        height="10"
                        viewBox="0 0 384 512"
                        width="10"
                        xmlns="http://www.w3.org/2000/svg"
                      >
                        <path
                          d="M169.4 470.6c12.5 12.5 32.8 12.5 45.3 0l160-160c12.5-12.5 12.5-32.8 0-45.3s-32.8-12.5-45.3 0L224 370.8V64c0-17.7-14.3-32-32-32s-32 14.3-32 32V370.8L54.6 265.4c-12.5-12.5-32.8-12.5-45.3 0s-12.5 32.8 0 45.3l160 160z"
                          fill="currentColor"
                        />
                      </svg>
                    </button>
                  </div>
                  <span class="category-node__reorder-position">{{positionLabel
                      index
                    }}</span>
                {{/if}}
                <a
                  class="category-node__topic-link"
                  href="/t/{{topic.slug}}/{{topic.id}}"
                >
                  {{topic.title}}
                </a>
                {{#if @isStaff}}
                  {{#unless this.reorderMode}}
                    <button
                      class="category-node__edit-btn"
                      title="Edit this topic"
                      type="button"
                      {{on "click" (fn @onEditTopic topic)}}
                    >
                      <svg
                        height="12"
                        viewBox="0 0 512 512"
                        width="12"
                        xmlns="http://www.w3.org/2000/svg"
                      >
                        <path
                          d="M410.3 231l11.3-11.3-33.9-33.9-62.1-62.1L291.7 89.8l-11.3 11.3-22.6 22.6L58.6 322.9c-10.4 10.4-18 23.3-22.2 37.4L1 480.7c-2.5 8.4-.2 17.5 6.1 23.7s15.3 8.5 23.7 6.1l120.3-35.4c14.1-4.2 27-11.8 37.4-22.2L387.7 253.7 410.3 231zM160 399.4l-9.1 22.7c-4 3.1-8.5 5.4-13.3 6.9L59.4 452l23-78.1c1.4-4.9 3.8-9.4 6.9-13.3l22.7-9.1v32c0 8.8 7.2 16 16 16h32zM362.7 18.7L348.3 33.2 325.7 55.8 314.3 67.1l33.9 33.9 62.1 62.1 33.9 33.9 11.3-11.3 22.6-22.6 14.5-14.5c25-25 25-65.5 0-90.5L453.3 18.7c-25-25-65.5-25-90.5 0z"
                          fill="currentColor"
                        />
                      </svg>
                    </button>
                    <button
                      class="category-node__delete-btn"
                      title="Permanently delete this topic"
                      type="button"
                      {{on "click" (fn @onDeleteTopic topic)}}
                    >
                      <svg
                        height="12"
                        viewBox="0 0 448 512"
                        width="12"
                        xmlns="http://www.w3.org/2000/svg"
                      >
                        <path
                          d="M135.2 17.7L128 32H32C14.3 32 0 46.3 0 64S14.3 96 32 96H416c17.7 0 32-14.3 32-32s-14.3-32-32-32H320l-7.2-14.3C307.4 6.8 296.3 0 284.2 0H163.8c-12.1 0-23.2 6.8-28.6 17.7zM416 128H32L53.2 467c1.6 25.3 22.6 45 47.9 45H346.9c25.3 0 46.3-19.7 47.9-45L416 128z"
                          fill="currentColor"
                        />
                      </svg>
                    </button>
                  {{/unless}}
                {{/if}}
              </li>
            {{/each}}
          </ul>
          {{#if this.hasMore}}
            <button
              class="category-node__see-more"
              type="button"
              {{on "click" this.toggleShowAll}}
            >
              {{#if this.showAll}}
                Show less
              {{else}}
                See more ({{this.remainingCount}})
              {{/if}}
            </button>
          {{/if}}
        {{/if}}
      {{/if}}
    </div>
  </template>
}
