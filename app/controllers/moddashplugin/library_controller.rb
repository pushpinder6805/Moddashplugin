# frozen_string_literal: true

module ::Moddashplugin
  class LibraryController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    before_action :prevent_shared_caching
    around_action :capture_resource_failure

    def index
      root_id = params.require(:root_id).to_i
      query = LibraryQuery.new(guardian, root_id, query: params[:q], cursor: params[:cursor])
      page = query.page
      result = {
        topics: serialize_data(page[:topics], ResourceTopicSerializer),
        next_cursor: page[:next_cursor],
      }
      if params[:cursor].blank?
        result[:categories] = serialize_data(query.categories, ResourceCategorySerializer)
        result[:order_config] = query.order_config
        result[:diagnostics] = {
          expected_topics: query.topics_scope.where("topics.id <= ?", page[:max_id] || 0).count,
          categories: query.categories.length,
        } if SiteSetting.moddashplugin_diagnostics_enabled
      end
      render_json_dump(result)
    end

    def update_order
      raise Discourse::InvalidAccess unless guardian.is_staff?
      category_id = params.require(:category_id).to_i
      root_id = params.require(:root_id).to_i
      query = LibraryQuery.new(guardian, root_id)
      raise Discourse::NotFound unless query.categories.any? { |cat| cat.id == category_id }
      ids = params[:ordered_ids]
      unless ids.is_a?(Array) && ids.length <= 20_000 &&
               ids.all? { |id| id.is_a?(Integer) && id > 0 }
        raise Discourse::InvalidParameters.new(:ordered_ids)
      end
      ids = ids.uniq
      allowed_ids = query.topics_scope.where(category_id: category_id, id: ids).pluck(:id)
      raise Discourse::InvalidParameters.new(:ordered_ids) unless (ids - allowed_ids).empty?
      PluginStore.set(PLUGIN_NAME, "order_#{category_id}", ids)
      render json: success_json
    end

    private

    def capture_resource_failure
      yield
    rescue StandardError => error
      code =
        case error
        when Discourse::NotFound
          "not_found"
        when Discourse::InvalidAccess
          "forbidden"
        when Discourse::InvalidParameters
          "invalid_request"
        else
          "server_exception"
        end
      Diagnostics.record(
        {
          event: "server_error",
          operation: action_name == "index" ? "load" : "reorder",
          code: code,
          root_id: params[:root_id],
          trace_id: request.headers["X-Moddash-Trace-ID"],
          request_id: request.request_id,
          exception_class: error.class.name,
          status:
            (
              if code == "not_found"
                404
              else
                (code == "forbidden" ? 403 : (code == "invalid_request" ? 400 : 500))
              end
            ),
        },
        user: current_user,
        source: "server",
      )
      raise
    end

    def prevent_shared_caching
      # Content and cursor validity depend on the signed-in user's permissions.
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Vary"] = "Cookie"
    end
  end
end
