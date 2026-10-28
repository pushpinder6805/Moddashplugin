# frozen_string_literal: true

module ::Moddashplugin
  class Diagnostics
    NAMESPACE = "moddashplugin-diagnostics"
    MAX_ENTRIES = 2000
    RETENTION_DAYS = 14
    EVENTS = %w[
      load_complete
      load_failed
      search_failed
      request_retry
      request_recovered
      action_failed
      client_error
      server_error
    ].freeze
    OPERATIONS = %w[load search reorder edit delete runtime].freeze
    CODES = %w[
      ok
      http_error
      timeout
      network_error
      invalid_response
      pagination_stalled
      count_changed
      unexpected_client_error
      server_exception
      not_found
      forbidden
      invalid_request
    ].freeze
    NUMBERS = %w[
      root_id
      status
      attempt
      page
      pages
      topics
      categories
      expected_topics
      duration_ms
      line
      column
    ].freeze
    IDENTIFIERS = %w[trace_id request_id exception_class client_version script].freeze

    def self.record(data, user: nil, source: "client")
      return unless SiteSetting.moddashplugin_diagnostics_enabled
      data = data.to_h.with_indifferent_access
      if EVENTS.exclude?(data[:event]) || OPERATIONS.exclude?(data[:operation]) ||
           CODES.exclude?(data[:code])
        return
      end
      item = {
        "id" =>
          (
            if data[:event_id].to_s.match?(/\A[a-zA-Z0-9-]{8,64}\z/)
              data[:event_id]
            else
              SecureRandom.uuid
            end
          ),
        "received_at" => Time.now.utc.iso8601(3),
        "event" => data[:event],
        "operation" => data[:operation],
        "code" => data[:code],
        "source" => source,
        "user_id" => user&.id,
        "username" => user&.username,
        "role" =>
          (
            if user&.admin?
              "admin"
            else
              (user&.moderator? ? "moderator" : (user ? "member" : "anonymous"))
            end
          ),
        "version" => "0.2.0",
        "revision" => Discourse.plugins_by_name[PLUGIN_NAME]&.commit_hash.to_s.first(12),
      }
      NUMBERS.each do |key|
        value = Integer(data[key], exception: false)
        item[key] = value if value && value.between?(0, 2_147_483_647)
      end
      IDENTIFIERS.each do |key|
        value = data[key].to_s
        item[key] = value if value.match?(/\A[a-zA-Z0-9_.:-]{1,100}\z/)
      end
      item["response_type"] = data[:response_type] if %w[json html other].include?(
        data[:response_type],
      )
      %w[online redirected].each do |key|
        item[key] = data[key] if [true, false].include?(data[key])
      end
      item["browser"] = data[:browser].to_s.gsub(%r{[^a-zA-Z0-9 ._();/:-]}, "").first(160)
      begin
        occurred = Time.iso8601(data[:occurred_at].to_s)
        item["occurred_at"] = occurred.utc.iso8601(3) if occurred.between?(
          2.days.ago,
          5.minutes.from_now,
        )
      rescue ArgumentError
        # The receive time remains authoritative when the client clock is wrong.
      end
      key = "event/#{item["id"]}"
      return if PluginStoreRow.exists?(plugin_name: NAMESPACE, key: key)
      PluginStore.set(NAMESPACE, key, item)
      rows = PluginStoreRow.where(plugin_name: NAMESPACE)
      rows.where(
        "value::jsonb ->> 'received_at' < ?",
        RETENTION_DAYS.days.ago.utc.iso8601(3),
      ).delete_all
      stale =
        rows
          .order(
            Arel.sql(
              "CASE WHEN value::jsonb ->> 'event' = 'load_complete' AND value::jsonb ->> 'code' = 'ok' THEN 1 ELSE 0 END ASC",
            ),
          )
          .order(id: :desc)
          .offset(MAX_ENTRIES)
          .limit(1000)
          .pluck(:id)
      rows.where(id: stale).delete_all if stale.present?
      item
    rescue StandardError => error
      # Diagnostics are best effort and must never replace the original failure.
      begin
        Rails.logger.warn("[Moddashplugin diagnostics] Could not store report: #{error.class.name}")
      rescue StandardError
        # A failed fallback logger must not mask the resource error either.
        nil
      end
      nil
    end

    def self.entries
      cutoff = RETENTION_DAYS.days.ago.utc.iso8601(3)
      PluginStoreRow
        .where(plugin_name: NAMESPACE)
        .where("value::jsonb ->> 'received_at' >= ?", cutoff)
        .order(id: :desc)
        .limit(MAX_ENTRIES)
        .map { |row| PluginStore.cast_value(row.type_name, row.value) }
    end

    def self.clear
      PluginStoreRow.where(plugin_name: NAMESPACE).delete_all
    end
  end
end
