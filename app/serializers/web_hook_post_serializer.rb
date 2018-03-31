class WebHookPostSerializer < PostSerializer

  attributes :user_email,
             :like_count,
             :full_url

  def include_topic_title?
    true
  end

  %i{
    can_view
    can_edit
    can_delete
    can_recover
    can_wiki
  }.each do |attr|
    define_method("include_#{attr}?") do
      false
    end
  end

  def user_email
    object.user.email
  end

end
