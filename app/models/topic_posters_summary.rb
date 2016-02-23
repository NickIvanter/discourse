class TopicPostersSummary
  attr_reader :topic, :options

  def initialize(topic, options = {})
    @topic = topic
    @options = options
    @guardian = Guardian.new(@options[:user])
  end

  def summary
    sorted_top_posters.compact.map(&method(:new_topic_poster_for))
  end

  private

  def new_topic_poster_for(user)
    TopicPoster.new.tap do |topic_poster|
      topic_poster.user = user
      topic_poster.description = descriptions_for(user)
      if topic.cloak_last_post_user_id(@guardian) == user.id
        topic_poster.extras = 'latest'
        topic_poster.extras << ' single' if user_ids.uniq.size == 1
      end
    end
  end

  def descriptions_by_id
    @descriptions_by_id ||= begin
      user_ids_with_descriptions.each_with_object({}) do |(id, description), descriptions|
        descriptions[id] ||= []
        descriptions[id] << description
      end
    end
  end

  def descriptions_for(user)
    descriptions_by_id[user.id].join ', '
  end

  def shuffle_last_poster_to_back_in(summary)
    unless last_poster_is_topic_creator?
      last_id = topic.cloak_last_post_user_id(@guardian)
      summary.reject!{ |u| u.id == last_id }
      summary << avatar_lookup[last_id]
    end
    summary
  end

  def user_ids_with_descriptions
    user_ids.zip([
      :original_poster,
      :most_recent_poster,
      :frequent_poster,
      :frequent_poster,
      :frequent_poster,
      :frequent_poster
      ].map { |description| I18n.t(description) })
  end

  def last_poster_is_topic_creator?
    topic.user_id == topic.cloak_last_post_user_id(@guardian)
  end

  def sorted_top_posters
    shuffle_last_poster_to_back_in top_posters
  end

  def top_posters
    user_ids.map { |id| avatar_lookup[id] }.compact.uniq.take(5)
  end

  def user_ids
    ids = [ topic.user_id, topic.cloak_last_post_user_id(@guardian), *topic.featured_user_ids ]
    return ids if !NewPostManager.stealth_enabled? || (@guardian.authenticated? && (@guardian.is_admin? || @guardian.is_moderator?))

    filter_cloaked(ids)
  end

  def filter_cloaked(ids)
    post_ids = topic.posts.cloak_stealth(@guardian).map { |p| p.user.id } # Only shown not cloaked ids
    result = Array.new

    post_ids & ids
  end

  def avatar_lookup
    @avatar_lookup ||= options[:avatar_lookup] || AvatarLookup.new(user_ids)
  end
end
