import Component from "@glimmer/component";
import { service } from "@ember/service";
import getURL from "discourse/lib/get-url";
import { resourceRoots } from "../../lib/resource-data.js";

export default class ResourceTopicBanner extends Component {
  @service siteSettings;

  get rootIds() {
    return resourceRoots(this.siteSettings).map((root) => root.id);
  }

  get topic() {
    return this.args.outletArgs?.model || this.args.model;
  }

  get resourceContext() {
    return this.topic?.moddashplugin_resource_context;
  }

  get category() {
    return this.topic?.category;
  }

  get isResourceTopic() {
    if (this.siteSettings.moddashplugin_enabled && this.resourceContext) {
      return true;
    }
    const cat = this.category;
    if (!this.siteSettings.moddashplugin_enabled || !cat) {
      return false;
    }
    let current = cat;
    while (current) {
      if (this.rootIds.includes(current.id)) {
        return true;
      }
      current = current.parentCategory;
    }
    return false;
  }

  get categoryBreadcrumbs() {
    if (this.resourceContext) {
      return this.resourceContext.breadcrumbs;
    }
    const crumbs = [];
    let current = this.category;
    while (current) {
      if (!this.rootIds.includes(current.id)) {
        crumbs.unshift(current);
      }
      current = current.parentCategory;
    }
    return crumbs;
  }

  get topicTitle() {
    return this.topic?.title || "";
  }

  get backUrl() {
    if (this.resourceContext) {
      return getURL(
        `/c/${this.resourceContext.root_slug}/${this.resourceContext.root_id}`
      );
    }
    let current = this.category;
    while (current) {
      if (this.rootIds.includes(current.id)) {
        return `/c/${current.slug}/${current.id}`;
      }
      current = current.parentCategory;
    }
    return "/c/resources/resource-library/10";
  }

  get firstPostContent() {
    return this.topic?.postStream?.posts?.[0]?.cooked || "";
  }

  <template>
    {{#if this.isResourceTopic}}
      <div class="resource-topic-view">
        <a class="resource-topic-view__back" href={{this.backUrl}}>
          &lsaquo; Back to Resource Library
        </a>

        <div class="resource-topic-view__banner">
          <div class="resource-topic-view__banner-content">
            <div class="resource-topic-view__tags">
              {{#each this.categoryBreadcrumbs as |cat|}}
                <span class="resource-topic-view__tag">{{cat.name}}</span>
              {{/each}}
            </div>
            <h1 class="resource-topic-view__title">{{this.topicTitle}}</h1>
          </div>
        </div>
      </div>
    {{/if}}
  </template>
}
