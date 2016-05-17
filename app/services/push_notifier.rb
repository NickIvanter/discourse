require 'net/http'

class PushNotifier

  def initialize(notification)
    if SiteSetting.push_notifications && notificationHasTranslation()
      @notification = notification
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
    I18n.t("#{@@i18nPushKey}}")[Notification.types[@notification.notification_type]]
  end

  def renderMessage(notification)
    message = I18n.t(
      "#{@@i18nPushKey}.#{Notification.types[notification.notification_type].to_s}",
      title: notification.topic.title
    )
  end

  def pushGCM(user: nil, message: nil)
    ids = UserDeviceIdField.new(user).get_ids_by_type('Android')
    unless ids.empty?
      sendPush(
        @@gcmUri,
        { 'Authorization' => "key=#{SiteSetting.push_notification_gcm_apikey}" },
        {
          'registration_ids' => ids,
          'data' => {
            'message' => message,
            'title' => SiteSetting.title,
            'vibrate' => 1,
            'sound' => 1
          }
        }
      )
    end
  end

  def pushAPNS(user: nil)
    ids = UserDeviceIdField.new(opts[:user]).get_ids_by_type('iOS')
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
    File.write '/tmp/send.log', "#{body.inspect}\n"
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
