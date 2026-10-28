# frozen_string_literal: true

module ::Moddashplugin
  class DiagnosticReportsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    def create
      response.headers["Cache-Control"] = "private, no-store"
      return head :no_content unless SiteSetting.moddashplugin_diagnostics_enabled
      bucket =
        current_user ? "user-#{current_user.id}" : Digest::SHA256.hexdigest(request.remote_ip.to_s)
      limiter =
        RateLimiter.new(
          current_user,
          "moddash-diagnostics-#{bucket}",
          30,
          1.minute,
          apply_limit_to_staff: true,
        )
      return head :too_many_requests unless limiter.performed!(raise_error: false)
      # A batch is deliberately small. Never accept arbitrary logs, URLs, stacks,
      # search terms or topic contents supplied by a client.
      events = params[:events]
      unless events.is_a?(Array) && events.length.between?(1, 10)
        raise Discourse::InvalidParameters.new(:events)
      end
      events.each do |event|
        next unless event.respond_to?(:permit)
        data =
          event.permit(
            :event_id,
            :response_type,
            :online,
            :redirected,
            :occurred_at,
            :event,
            :operation,
            :code,
            :browser,
            *Diagnostics::NUMBERS,
            *Diagnostics::IDENTIFIERS,
          ).to_h
        next unless Diagnostics.valid?(data)
        stored = Diagnostics.record(data, user: current_user)
        return head :service_unavailable unless stored
      end
      head :no_content
    end
  end
end
