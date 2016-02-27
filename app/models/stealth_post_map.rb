class StealthPostMap < ActiveRecord::Base
  belongs_to :post
  belongs_to :topic

  def new_topic?
    topic_id # set if topic is new
  end
end
