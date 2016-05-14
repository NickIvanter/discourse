class UserDeviceIdUpdater

  def initialize(user)
    @user = user
  end

  def update(attributes = {})
    UserCustomField.transaction do
      @device_ids_field_id = UserField.where(name: "device_ids").pluck(:id).first
      @field_name = "user_field_#{@device_ids_field_id}"
      @device_ids = UserCustomField.where(name: @field_name, user_id: @user.id).first;

      if @device_ids
        ids = JSON.parse(@device_ids.value)
        unless ids.include? attributes[:device_id]
          ids << attributes[:device_id]
          @device_ids.value = ids.to_json
          @device_ids.save!
        end
      else
        UserCustomField.new(name: @field_name, value: [attributes[:device_id]].to_json, user_id: @user.id).save
      end
    end

    @user
  end

end
