require 'net/http'

class PushNotifier

  def initialize(notification)
    @notification = notification
    if SiteSetting.push_notifications && notificationHasTranslation()
      @message = renderMessage()
    else
      @notification = nil
    end
  end

  def publish()
    if @notification
      pushGCM() unless SiteSetting.push_notification_gcm_apikey.empty?
      pushAPNS() unless SiteSetting.push_notification_apns_apikey.empty?
    end
  end

  private

  @@i18nPushKey ="js.notifications.push"

  @@gcmUri = URI.parse('https://android.googleapis.com/gcm/send');
  @@apnsUri = URI.parse('https://android.googleapis.com/gcm/send'); # TBD
  # @@gcmUri = URI.parse('http://localhost:7777')
  # @@apnsUri = URI.parse('http://localhost:7777') # TBD

  def notificationHasTranslation()
    I18n.t("#{@@i18nPushKey}")[Notification.types[@notification.notification_type]]
  end

  def renderMessage()
    data = JSON.parse(@notification.data)

    if data['real_name']
      username = data['real_name']
    elsif data['original_username']
      username = data['original_username']
    elsif data['username']
      username = data['username']
    else
      username = nil
    end

    if data['topic_title']
      title = data['topic_title']
    else
      title = nil
    end

    # TODO Badge?

    I18n.t(
      "#{@@i18nPushKey}.#{Notification.types[@notification.notification_type].to_s}",
      topic: title,
      username: username
    )
  end

  def pushGCM()
    ids = UserDeviceIdField.new(@notification.user).get_ids_by_type('Android')
    unless ids.empty?
      sendPush(
        @@gcmUri,
        { 'Authorization' => "key=#{SiteSetting.push_notification_gcm_apikey}" },
        {
          'registration_ids' => ids,
          'data' => {
            'message' => @message,
            'title' => SiteSetting.title,
            'vibrate' => 1,
            'sound' => 1
          }
        }
      )
    end
  end

  def pushAPNS()
    ids = UserDeviceIdField.new(@notification.user).get_ids_by_type('iOS')
    unless ids.empty?
      sendPush(
        @@apnsUri,
        { 'Authorization' => "key=#{SiteSetting.push_notification_apns_apikey}" },
        {
        }
      )
    end
  end

  def sendPush(uri, headers, body)
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    headers.each do |key, value|
      req[key] = value
    end
    req.body = body.to_json

    begin
      Net::HTTP.start(
        uri.hostname,
        uri.port,
        :use_ssl => uri.scheme == 'https'
      ) do |http|
        http.request(req)
      end
    rescue
      true
    end
  end
end
