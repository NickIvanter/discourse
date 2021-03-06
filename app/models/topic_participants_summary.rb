# This is used on a topic page
class TopicParticipantsSummary
  attr_reader :topic, :options

  def initialize(topic, options = {})
    @topic = topic
    @options = options
    @user = options[:user]
    @guardian = Guardian.new(@user)

    if NewPostManager.queued_preview_enabled?
      @post_ids = topic.posts.hide_queued_preview(@guardian).pluck(:user_id) # Only show not queued_preview ids
    end
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

    if !NewPostManager.queued_preview_enabled? || @guardian.can_see_queued_preview?
      ids
    else
      @post_ids & ids
    end
  end

  def avatar_lookup
    @avatar_lookup ||= options[:avatar_lookup] || AvatarLookup.new(user_ids)
  end
end
