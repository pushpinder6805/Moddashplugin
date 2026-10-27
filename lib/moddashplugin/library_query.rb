# frozen_string_literal: true

module ::Moddashplugin
  class LibraryQuery
    PAGE_SIZE = 100
    CURSOR_PURPOSE = "moddashplugin-library-v1"

    def initialize(guardian, root_id, query: nil, cursor: nil)
      @guardian = guardian
      @root_id = root_id
      @query = query.to_s.strip[0, 256]
      @cursor = cursor
    end

    def self.root_ids
      SiteSetting
        .moddashplugin_root_category_ids
        .split("|")
        .filter_map { |value| Integer(value, exception: false) }
    end

    def self.topic_context(guardian, category_id)
      return if category_id.blank?
      roots = root_ids
      return if roots.empty?
      ancestors = Category.secured(guardian).with_ancestors(category_id).index_by(&:id)
      current = ancestors[category_id]
      breadcrumbs = []
      seen = Set.new
      while current && seen.add?(current.id)
        if roots.include?(current.id)
          return { root_id: current.id, root_slug: current.slug, breadcrumbs: breadcrumbs }
        end
        breadcrumbs.unshift({ id: current.id, name: current.name })
        current = ancestors[current.parent_category_id]
      end
      nil
    end

    def categories
      @categories ||=
        begin
          raise Discourse::NotFound if self.class.root_ids.exclude?(@root_id)
          # Fetch the secured directory in one query, including categories omitted
          # from the browser bootstrap or the lazy-loaded category directory.
          all = Category.secured(@guardian).order(:position, :id).to_a
          root = all.find { |category| category.id == @root_id }
          raise Discourse::NotFound unless root
          children = all.group_by(&:parent_category_id)
          found = []
          queue = [root]
          seen = Set.new
          until queue.empty?
            category = queue.shift
            next unless seen.add?(category.id)
            found << category
            queue.concat(children[category.id] || [])
          end
          found
        end
    end

    def topics_scope
      @topics_scope ||=
        begin
          scope =
            @guardian.filter_allowed_categories(Topic.listable_topics).where(
              category_id: categories.map(&:id),
            )
          scope = scope.visible unless @guardian.can_see_unlisted_topics?
          scope = scope.where.not(id: categories.filter_map(&:topic_id))
          # Shared drafts must never appear in the library, even for staff.
          scope = scope.where.not(id: SharedDraft.select(:topic_id))
          scope = scope.where.not(category_id: SiteSetting.shared_drafts_category.to_i)
          if @query.present?
            scope = scope.where("topics.title ILIKE ?", "%#{Topic.sanitize_sql_like(@query)}%")
          end
          scope
        end
    end

    def page
      state = decode_cursor
      scope = topics_scope
      max_id = state ? state["max_id"] : scope.maximum(:id)
      scope = scope.where("topics.id <= ?", max_id) if max_id
      if state
        scope =
          scope.where("(topics.created_at, topics.id) < (?, ?)", state["created_at"], state["id"])
      end
      records = scope.reorder(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).to_a
      has_more = records.length > PAGE_SIZE
      records = records.first(PAGE_SIZE)
      next_cursor = nil
      if has_more
        last = records.last
        next_cursor =
          verifier.generate(
            {
              root_id: @root_id,
              user_id: @guardian.user&.id,
              query: @query,
              max_id: max_id,
              created_at: last.created_at.iso8601(6),
              id: last.id,
            },
            purpose: CURSOR_PURPOSE,
            expires_in: 1.hour,
          )
      end
      { topics: records, next_cursor: next_cursor }
    end

    def order_config
      keys = categories.map { |category| "order_#{category.id}" }
      stored = PluginStore.get_all(PLUGIN_NAME, keys)
      config = {}
      categories.each do |category|
        ids = stored["order_#{category.id}"]
        config[category.id.to_s] = ids if ids.is_a?(Array)
      end
      # A staff member may have ordered an unlisted topic. Do not expose even
      # those topic IDs to members who cannot see them.
      allowed = topics_scope.where(id: config.values.flatten).pluck(:id).to_set
      config.transform_values do |ids|
        {
          orderedIds:
            ids
              .filter_map { |id| Integer(id, exception: false) }
              .select { |id| allowed.include?(id) },
        }
      end
    end

    private

    def verifier
      Rails.application.message_verifier(PLUGIN_NAME)
    end

    def decode_cursor
      return if @cursor.blank?
      value = verifier.verified(@cursor, purpose: CURSOR_PURPOSE)&.with_indifferent_access
      unless value && value[:root_id] == @root_id && value[:user_id] == @guardian.user&.id &&
               value[:query] == @query
        raise Discourse::InvalidParameters.new(:cursor)
      end
      value
    end
  end
end
