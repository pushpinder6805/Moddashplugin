import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "moddash-diagnostics",
  initialize(container) {
    const diagnostics = container.lookup("service:moddash-diagnostics");
    diagnostics.installErrorCapture();
    if (container.lookup("service:current-user")?.admin) {
      withPluginApi((api) =>
        api.addAdminPluginConfigurationNav("moddashplugin", [
          {
            label: "moddashplugin.diagnostics.title",
            route: "adminPlugins.show.moddashplugin-diagnostics",
            description: "moddashplugin.diagnostics.description",
          },
        ])
      );
    }
  },
};
