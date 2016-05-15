class UserDeviceIdField

  attr_accessor :device_ids
  attr_accessor :ids

  def initialize(user)
    @user = user
    @device_ids_field_id = UserField.where(name: "device_ids").pluck(:id).first
    @field_name = "user_field_#{@device_ids_field_id}"
    @device_ids = UserCustomField.where(name: @field_name, user_id: @user.id).first;
    if @device_ids.present? && @device_ids.value.present? && !@device_ids.value.empty?
      begin
        @ids = JSON.parse(@device_ids.value)
      rescue
        @ids = []
      end
    else
      @ids = []
    end
  end

  def push_new(id:, type:)
    item = {"id" => id, "type" => type}

    if @ids.empty?
      UserCustomField.new(name: @field_name, value: [item].to_json, user_id: @user.id).save
    elsif !(@ids.include? item)
      @ids << item
      @device_ids.value = ids.to_json
      @device_ids.save!
    end
  end

  def get_ids_by_type(type)
    (@ids.select do |item|
      item['id'] if item['type'] == type
     end).map do |item|
      item['id']
    end
  end

  def save!
    @device_ids.save!
  end

end
