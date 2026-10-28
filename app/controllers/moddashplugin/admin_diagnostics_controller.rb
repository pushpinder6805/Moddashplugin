# frozen_string_literal: true

module ::Moddashplugin
  # Admin-only incident history remains readable after disabling the library.
  # rubocop:disable Discourse/Plugins/CallRequiresPlugin
  class AdminDiagnosticsController < ::Admin::AdminController
    def index
      response.headers["Cache-Control"] = "private, no-store"
      render_json_dump(
        entries: Diagnostics.entries,
        enabled: SiteSetting.moddashplugin_diagnostics_enabled,
        retention_days: Diagnostics::RETENTION_DAYS,
        max_entries: Diagnostics::MAX_ENTRIES,
      )
    end

    def destroy
      Diagnostics.clear
      head :no_content
    end
  end
  # rubocop:enable Discourse/Plugins/CallRequiresPlugin
end
