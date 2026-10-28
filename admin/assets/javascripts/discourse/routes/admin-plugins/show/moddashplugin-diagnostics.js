import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class ModdashpluginDiagnosticsRoute extends DiscourseRoute {
  model() {
    return ajax("/moddashplugin/admin/diagnostics.json");
  }
}
