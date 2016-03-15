require_dependency 'stealth_post_map'
require_dependency 'has_errors'

class PostStealthMapper
  include HasErrors

  def initialize(enqueue_result, post_result)
    @queue = enqueue_result
    @post = post_result
  end

  def cloak
    # topic_id is null for old topic, id for new topic
    mapping = StealthPostMap.new(
      queued_id: @queue.queued_post.id,
      post_id: @post.post.id,
      topic_id: @queue.queued_post.topic_id ? nil : @post.post.topic_id
    )
    add_errors_from(mapping) unless mapping.save

    mapping
  end

end
