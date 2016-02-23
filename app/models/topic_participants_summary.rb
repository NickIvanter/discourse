class TopicParticipantsSummary
  attr_reader :topic, :options

  def initialize(topic, options = {})
    @topic = topic
    @options = options
    @user = options[:user]
    @guardian = Guardian.new(@user)
  end

  def summary
    top_participants.compact.map(&method(:new_topic_poster_for))
  end

  def new_topic_poster_for(user)
    TopicPoster.new.tap do |topic_poster|
      topic_poster.user = user
      topic_poster.extras = 'latest' if is_latest_poster?(user)
    end
  end

  def is_latest_poster?(user)
    topic.last_post_user_id == user.id
  end

  def top_participants
    user_ids.map { |id| avatar_lookup[id] }.compact.uniq.take(3)
  end

  def user_ids
    return [] unless @user
    ids = [topic.user_id] + topic.allowed_user_ids - [@user.id]

    return ids if !NewPostManager.stealth_enabled? || (@guardian.authenticated? && (@guardian.is_admin? || @guardian.is_moderator?))

    filter_cloaked(ids)
  end

  def filter_cloaked(ids)
    post_ids = topic.posts.cloak_stealth(@guardian).map { |p| p.user.id } # Only shown not cloaked ids

    result = post_ids & ids
    File.open('/tmp/ids.log','a').write "#{ids} & #{post_ids} = #{result}\n#{topic.inspect}\n"
    result
  end

  def avatar_lookup
    @avatar_lookup ||= options[:avatar_lookup] || AvatarLookup.new(user_ids)
  end
end
