require 'net/http'

class PushNotifier
  class << self
    def publish(notification)
      if SiteSetting.push_notifications
        unless SiteSetting.push_notification_gcm_apikey.empty?
          pushGCM(user: notification.user)
        end
        unless SiteSetting.push_notification_apns_apikey.empty?
          pushAPNS(user: notification.user)
        end
      end
    end

    private

    @@gcmUri = URI.parse('https://android.googleapis.com/gcm/send');
    @@apnsUri = URI.parse('https://android.googleapis.com/gcm/send'); # TBD
    # @@gcmUri = URI.parse('http://localhost:7777')
    # @@apnsUri = URI.parse('http://localhost:7777') # TBD

    def pushGCM(user: nil)
      ids = UserDeviceIdField.new(user).get_ids_by_type('Android')
      unless ids.empty?
        sendPush(
          @@gcmUri,
          { 'Authorization' => "key=#{SiteSetting.push_notification_gcm_apikey}" },
          {
            'registration_ids' => ids,
            'data' => {
              'message' => 'NEVER MIND DUDE!',
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
end
