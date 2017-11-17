class AboutSerializer < ApplicationSerializer
  has_many :moderators, serializer: UserNameSerializer, embed: :objects
  has_many :admins, serializer: UserNameSerializer, embed: :objects

  attributes :stats,
             :description,
             :title,
             :locale,
             :version,
             :https,
             :staff

  def stats
    object.class.fetch_cached_stats || Jobs::AboutStats.new.execute({})
  end

  def staff
    scope.is_staff?
  end
end
