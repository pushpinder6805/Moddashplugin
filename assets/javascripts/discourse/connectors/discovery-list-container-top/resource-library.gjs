import Component from "@glimmer/component";
import { array } from "@ember/helper";
import { service } from "@ember/service";
import ResourceLibrary from "../../components/resource-library.gjs";
import { resourceRoots } from "../../lib/resource-data.js";

export default class ResourceLibraryConnector extends Component {
  @service siteSettings;

  get shouldShow() {
    const category = this.args.outletArgs?.category;
    if (!category) {
      return false;
    }
    return (
      this.siteSettings.moddashplugin_enabled &&
      resourceRoots(this.siteSettings).some((root) => root.id === category.id)
    );
  }

  get currentCategory() {
    return this.args.outletArgs?.category;
  }

  <template>
    {{#if this.shouldShow}}
      {{#each (array this.currentCategory) key="id" as |category|}}
        <ResourceLibrary @category={{category}} />
      {{/each}}
    {{/if}}
  </template>
}
