class UserHellbanner

  def initialize(user)
    @user = user
  end

  def self.enabled?
    SiteSetting.hellban_mode
  end

  def enabled?
    self.class.hellban?
  end

  def user_banned?
    @user.blocked?
  end

end
