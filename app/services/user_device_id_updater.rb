class UserDeviceIdUpdater

  def initialize(user)
    @user = user
  end

  def update(attributes = {})
    UserCustomField.transaction do
      @device_ids = UserDeviceIdField.new(@user)
      @device_ids.push_new(id: attributes[:device_id], type: attributes[:type])
      @user
    end
  end
end
