export default {
  resource: "admin.adminPlugins.show",
  path: "/plugins",
  map() {
    this.route("moddashplugin-diagnostics", { path: "diagnostics" });
  },
};
