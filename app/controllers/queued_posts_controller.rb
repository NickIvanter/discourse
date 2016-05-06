require_dependency 'queued_post_serializer'

class QueuedPostsController < ApplicationController

  before_filter :ensure_staff

  def index
    state_query = params[:state] || 'new'
    state = QueuedPost.states[(state_query).to_sym]
    state ||= QueuedPost.states[:new]

    limit_query = params[:limit] || 100;

    @queued_posts = QueuedPost.visible.where(state: state).includes(:topic, :user).order(:created_at)
                    .limit(limit_query)
    render_serialized(@queued_posts,
                      QueuedPostSerializer,
                      root: :queued_posts,
                      rest_serializer: true,
                      refresh_queued_posts: "/queued_posts?state=#{state_query}&limit=#{limit_query}")

  end

  def update
    qp = QueuedPost.where(id: params[:id]).first

    if params[:queued_post][:raw].present?
      qp.edit_content!(params[:queued_post][:raw])
    end

    state = params[:queued_post][:state]
    if state == 'approved'
      qp.approve!(current_user)
    elsif state == 'rejected'
      qp.reject!(current_user)
      if params[:queued_post][:delete_user] == 'true' && guardian.can_delete_user?(qp.user)
        UserDestroyer.new(current_user).destroy(qp.user, user_deletion_opts)
      end
    end

    render_serialized(qp, QueuedPostSerializer, root: :queued_posts)
  end


  private

    def user_deletion_opts
      base = {
        context:           I18n.t('queue.delete_reason', {performed_by: current_user.username}),
        delete_posts:      true,
        delete_as_spammer: true
      }

      if Rails.env.production? && ENV["Staging"].nil?
        base.merge!({block_email: true, block_ip: true})
      end

      base
    end

end
