require "digest"
require_dependency "new_post_manager"
require_dependency "post_action_creator"
require_dependency "html_to_markdown"
require_dependency "upload_creator"

module Email

  class Receiver
    include ActionView::Helpers::NumberHelper

    class ProcessingError              < StandardError; end
    class EmptyEmailError              < ProcessingError; end
    class ScreenedEmailError           < ProcessingError; end
    class UserNotFoundError            < ProcessingError; end
    class AutoGeneratedEmailError      < ProcessingError; end
    class BouncedEmailError            < ProcessingError; end
    class NoBodyDetectedError          < ProcessingError; end
    class InactiveUserError            < ProcessingError; end
    class BlockedUserError             < ProcessingError; end
    class BadDestinationAddress        < ProcessingError; end
    class StrangersNotAllowedError     < ProcessingError; end
    class InsufficientTrustLevelError  < ProcessingError; end
    class ReplyUserNotMatchingError    < ProcessingError; end
    class TopicNotFoundError           < ProcessingError; end
    class TopicClosedError             < ProcessingError; end
    class InvalidPost                  < ProcessingError; end
    class InvalidPostAction            < ProcessingError; end

    attr_reader :incoming_email
    attr_reader :raw_email
    attr_reader :mail
    attr_reader :message_id

    def initialize(mail_string)
      raise EmptyEmailError if mail_string.blank?
      @staged_users_created = 0
      @raw_email = try_to_encode(mail_string, "UTF-8") || try_to_encode(mail_string, "ISO-8859-1") || mail_string
      @mail = Mail.new(@raw_email)
      @message_id = @mail.message_id.presence || Digest::MD5.hexdigest(mail_string)
    end

    def process!
      return if is_blacklisted?
      DistributedMutex.synchronize(@message_id) do
        begin
          return if IncomingEmail.exists?(message_id: @message_id)
          @from_email, @from_display_name = parse_from_field(@mail)
          @incoming_email = create_incoming_email
          process_internal
        rescue => e
          @incoming_email.update_columns(error: e.to_s) if @incoming_email
          raise
        end
      end
    end

    def is_blacklisted?
      return false if SiteSetting.ignore_by_title.blank?
      Regexp.new(SiteSetting.ignore_by_title) =~ @mail.subject
    end

    def create_incoming_email
      IncomingEmail.create(
        message_id: @message_id,
        raw: @raw_email,
        subject: subject,
        from_address: @from_email,
        to_addresses: @mail.to&.map(&:downcase)&.join(";"),
        cc_addresses: @mail.cc&.map(&:downcase)&.join(";"),
      )
    end

    def process_internal
      raise BouncedEmailError  if is_bounce?
      raise ScreenedEmailError if ScreenedEmail.should_block?(@from_email)

      user = find_or_create_user(@from_email, @from_display_name)

      raise UserNotFoundError if user.nil?

      @incoming_email.update_columns(user_id: user.id)

      raise InactiveUserError if !user.active && !user.staged
      raise BlockedUserError  if user.blocked

      body, elided = select_body
      body ||= ""

      raise NoBodyDetectedError if body.blank? && attachments.empty?

      if is_auto_generated?
        @incoming_email.update_columns(is_auto_generated: true)
        raise AutoGeneratedEmailError if SiteSetting.block_auto_generated_emails?
      end

      if action = subscription_action_for(body, subject)
        message = SubscriptionMailer.send(action, user)
        Email::Sender.new(message, :subscription).send
      elsif post = find_related_post
        create_reply(user: user,
                     raw: body,
                     elided: elided,
                     post: post,
                     topic: post.topic,
                     skip_validations: user.staged?)
      else
        first_exception = nil

        destinations.each do |destination|
          begin
            process_destination(destination, user, body, elided)
          rescue => e
            first_exception ||= e
          else
            return
          end
        end

        raise first_exception || BadDestinationAddress
      end
    end

    def is_bounce?
      return false unless @mail.bounced? || verp

      @incoming_email.update_columns(is_bounce: true)

      if verp && (bounce_key = verp[/\+verp-(\h{32})@/, 1]) && (email_log = EmailLog.find_by(bounce_key: bounce_key))
        email_log.update_columns(bounced: true)
        email = email_log.user.try(:email).presence
      end

      email ||= @from_email

      if @mail.error_status.present? && @mail.error_status.start_with?("4.")
        Email::Receiver.update_bounce_score(email, SiteSetting.soft_bounce_score)
      else
        Email::Receiver.update_bounce_score(email, SiteSetting.hard_bounce_score)
      end

      true
    end

    def verp
      @verp ||= all_destinations.select { |to| to[/\+verp-\h{32}@/] }.first
    end

    def self.update_bounce_score(email, score)
      # only update bounce score once per day
      key = "bounce_score:#{email}:#{Date.today}"

      if $redis.setnx(key, "1")
        $redis.expire(key, 25.hours)

        if user = User.find_by(email: email)
          user.user_stat.bounce_score += score
          user.user_stat.reset_bounce_score_after = SiteSetting.reset_bounce_score_after_days.days.from_now
          user.user_stat.save

          bounce_score = user.user_stat.bounce_score
          if user.active && bounce_score >= SiteSetting.bounce_score_threshold_deactivate
            user.update_columns(active: false)
            reason = I18n.t("user.deactivated", email: user.email)
            StaffActionLogger.new(Discourse.system_user).log_user_deactivate(user, reason)
          elsif bounce_score >= SiteSetting.bounce_score_threshold
            # NOTE: we check bounce_score before sending emails, nothing to do
            # here other than log it happened.
            reason = I18n.t("user.email.revoked", { email: user.email, date: user.user_stat.reset_bounce_score_after })
            StaffActionLogger.new(Discourse.system_user).log_revoke_email(user, reason)
          end
        end

        true
      else
        false
      end
    end

    def is_auto_generated?
      return false if SiteSetting.auto_generated_whitelist.split('|').include?(@from_email)
      @mail[:precedence].to_s[/list|junk|bulk|auto_reply/i] ||
      @mail[:from].to_s[/(mailer[\-_]?daemon|post[\-_]?master|no[\-_]?reply)@/i] ||
      @mail[:subject].to_s[/^\s*(Auto:|Automatic reply|Autosvar|Automatisk svar|Automatisch antwoord|Abwesenheitsnotiz|Risposta Non al computer|Automatisch antwoord|Auto Response|Respuesta automática|Fuori sede|Out of Office|Frånvaro|Réponse automatique)/i] ||
      @mail.header.to_s[/auto[\-_]?(response|submitted|replied|reply|generated|respond)|holidayreply|machinegenerated/i]
    end

    def select_body
      text = nil
      html = nil

      if @mail.multipart?
        text = fix_charset(@mail.text_part)
        html = fix_charset(@mail.html_part)
      elsif @mail.content_type.to_s["text/html"]
        html = fix_charset(@mail)
      else
        text = fix_charset(@mail)
      end

      text, elided_text = if text.present?
        text = trim_discourse_markers(text)
        EmailReplyTrimmer.trim(text, true)
      end

      markdown, elided_markdown = if html.present?
        markdown = HtmlToMarkdown.new(html, keep_img_tags: true, keep_cid_imgs: true).to_markdown
        markdown = trim_discourse_markers(markdown)
        EmailReplyTrimmer.trim(markdown, true)
      end

      if text.blank? || (SiteSetting.incoming_email_prefer_html && markdown.present?)
        return [markdown, elided_markdown]
      else
        return [text, elided_text]
      end
    end

    def fix_charset(mail_part)
      return nil if mail_part.blank? || mail_part.body.blank?

      string = mail_part.body.decoded rescue nil

      return nil if string.blank?

      # common encodings
      encodings = ["UTF-8", "ISO-8859-1"]
      encodings.unshift(mail_part.charset) if mail_part.charset.present?

      # mail (>=2.5) decodes mails with 8bit transfer encoding to utf-8, so
      # always try UTF-8 first
      if mail_part.content_transfer_encoding == "8bit"
        encodings.delete("UTF-8")
        encodings.unshift("UTF-8")
      end

      encodings.uniq.each do |encoding|
        fixed = try_to_encode(string, encoding)
        return fixed if fixed.present?
      end

      nil
    end

    def try_to_encode(string, encoding)
      encoded = string.encode("UTF-8", encoding)
      !encoded.nil? && encoded.valid_encoding? ? encoded : nil
    rescue Encoding::InvalidByteSequenceError,
           Encoding::UndefinedConversionError,
           Encoding::ConverterNotFoundError
      nil
    end

    def previous_replies_regex
      @previous_replies_regex ||= /^--[- ]\n\*#{I18n.t("user_notifications.previous_discussion")}\*\n/im
    end

    def trim_discourse_markers(reply)
      reply.split(previous_replies_regex)[0]
    end

    def parse_from_field(mail)
      return unless mail[:from]

      if mail[:from].errors.blank?
        mail[:from].address_list.addresses.each do |address_field|
          address_field.decoded
          from_address = address_field.address
          from_display_name = address_field.display_name.try(:to_s)
          return [from_address&.downcase, from_display_name&.strip] if from_address["@"]
        end
      end

      if mail.from[/<[^>]+>/]
        from_address = mail.from[/<([^>]+)>/, 1]
        from_display_name = mail.from[/^([^<]+)/, 1]
      end

      if (from_address.blank? || !from_address["@"]) && mail.from[/\[mailto:[^\]]+\]/]
        from_address = mail.from[/\[mailto:([^\]]+)\]/, 1]
        from_display_name = mail.from[/^([^\[]+)/, 1]
      end

      [from_address&.downcase, from_display_name&.strip]
    end

    def subject
      @suject ||= @mail.subject.presence || I18n.t("emails.incoming.default_subject", email: @from_email)
    end

    def find_or_create_user(email, display_name)
      user = nil

      User.transaction do
        begin
          user = User.find_by_email(email)

          if user.nil? && SiteSetting.enable_staged_users
            username = UserNameSuggester.sanitize_username(display_name) if display_name.present?
            user = User.create!(
              email: email,
              username: UserNameSuggester.suggest(username.presence || email),
              name: display_name.presence || User.suggest_name(email),
              staged: true
            )
            @staged_users_created += 1
          end
        rescue
          user = nil
        end
      end

      user
    end

    def all_destinations
      @all_destinations ||= [
        @mail.destinations,
        [@mail[:x_forwarded_to]].flatten.compact.map(&:decoded),
        [@mail[:delivered_to]].flatten.compact.map(&:decoded),
      ].flatten.select(&:present?).uniq.lazy
    end

    def destinations
      all_destinations
        .map { |d| Email::Receiver.check_address(d) }
        .drop_while(&:blank?)
    end

    def self.check_address(address)
      # only check for a group/category when 'email_in' is enabled
      if SiteSetting.email_in
        group = Group.find_by_email(address)
        return { type: :group, obj: group } if group

        category = Category.find_by_email(address)
        return { type: :category, obj: category } if category
      end

      # reply
      match = Email::Receiver.reply_by_email_address_regex.match(address)
      if match && match.captures
        match.captures.each do |c|
          next if c.blank?
          email_log = EmailLog.for(c)
          return { type: :reply, obj: email_log } if email_log
        end
      end
    end

    def process_destination(destination, user, body, elided)
      return if SiteSetting.enable_forwarded_emails &&
                has_been_forwarded? &&
                process_forwarded_email(destination, user)

      case destination[:type]
      when :group
        group = destination[:obj]
        create_topic(user: user,
                     raw: body,
                     elided: elided,
                     title: subject,
                     archetype: Archetype.private_message,
                     target_group_names: [group.name],
                     is_group_message: true,
                     skip_validations: true)

      when :category
        category = destination[:obj]

        raise StrangersNotAllowedError    if user.staged? && !category.email_in_allow_strangers
        raise InsufficientTrustLevelError if !user.has_trust_level?(SiteSetting.email_in_min_trust)

        create_topic(user: user,
                     raw: body,
                     title: subject,
                     category: category.id,
                     skip_validations: user.staged?)

      when :reply
        email_log = destination[:obj]

        if email_log.user_id != user.id
          raise ReplyUserNotMatchingError, "email_log.user_id => #{email_log.user_id.inspect}, user.id => #{user.id.inspect}"
        end

        create_reply(user: user,
                     raw: body,
                     elided: elided,
                     post: email_log.post,
                     topic: email_log.post.topic,
                     skip_validations: user.staged?)
      end
    end

    def has_been_forwarded?
      subject[/^[[:blank:]]*(fwd?|tr)[[:blank:]]?:/i] && embedded_email_raw.present?
    end

    def embedded_email_raw
      return @embedded_email_raw if @embedded_email_raw
      text = fix_charset(@mail.multipart? ? @mail.text_part : @mail)
      @embedded_email_raw, @before_embedded = EmailReplyTrimmer.extract_embedded_email(text)
      @embedded_email_raw
    end

    def process_forwarded_email(destination, user)
      embedded = Mail.new(embedded_email_raw)
      email, display_name = parse_from_field(embedded)

      return false if email.blank? || !email["@"]

      embedded_user = find_or_create_user(email, display_name)
      raw = try_to_encode(embedded.decoded, "UTF-8").presence || embedded.to_s
      title = embedded.subject.presence || subject

      case destination[:type]
      when :group
        group = destination[:obj]
        post = create_topic(user: embedded_user,
                            raw: raw,
                            title: title,
                            archetype: Archetype.private_message,
                            target_usernames: [user.username],
                            target_group_names: [group.name],
                            is_group_message: true,
                            skip_validations: true,
                            created_at: embedded.date)

      when :category
        category = destination[:obj]

        return false if user.staged? && !category.email_in_allow_strangers
        return false if !user.has_trust_level?(SiteSetting.email_in_min_trust)

        post = create_topic(user: embedded_user,
                            raw: raw,
                            title: title,
                            category: category.id,
                            skip_validations: embedded_user.staged?,
                            created_at: embedded.date)
      else
        return false
      end

      if post&.topic
        # mark post as seen for the forwarder
        PostTiming.record_timing(user_id: user.id, topic_id: post.topic_id, post_number: post.post_number, msecs: 5000)

        # create reply when available
        if @before_embedded.present?
          post_type = Post.types[:regular]
          post_type = Post.types[:whisper] if post.topic.private_message? && group.usernames[user.username]

          create_reply(user: user,
                       raw: @before_embedded,
                       post: post,
                       topic: post.topic,
                       post_type: post_type,
                       skip_validations: user.staged?)
        end
      end

      true
    end

    def self.reply_by_email_address_regex(extract_reply_key=true)
      reply_addresses = [SiteSetting.reply_by_email_address]
      reply_addresses << (SiteSetting.alternative_reply_by_email_addresses.presence || "").split("|")

      reply_addresses.flatten!
      reply_addresses.select!(&:present?)
      reply_addresses.map! { |a| Regexp.escape(a) }
      reply_addresses.map! { |a| a.gsub(Regexp.escape("%{reply_key}"), "(\\h{32})") }

      /#{reply_addresses.join("|")}/
    end

    def group_incoming_emails_regex
      @group_incoming_emails_regex ||= Regexp.union Group.pluck(:incoming_email).select(&:present?).map { |e| e.split("|") }.flatten.uniq
    end

    def category_email_in_regex
      @category_email_in_regex ||= Regexp.union Category.pluck(:email_in).select(&:present?).map { |e| e.split("|") }.flatten.uniq
    end

    def find_related_post
      return if SiteSetting.find_related_post_with_key

      message_ids = [@mail.in_reply_to, Email::Receiver.extract_references(@mail.references)]
      message_ids.flatten!
      message_ids.select!(&:present?)
      message_ids.uniq!
      return if message_ids.empty?

      message_ids = message_ids.first(5)

      host = Email::Sender.host_for(Discourse.base_url)
      post_id_regexp  = Regexp.new "topic/\\d+/(\\d+)@#{Regexp.escape(host)}"
      topic_id_regexp = Regexp.new "topic/(\\d+)@#{Regexp.escape(host)}"

      post_ids =  message_ids.map { |message_id| message_id[post_id_regexp, 1] }.compact.map(&:to_i)
      post_ids << Post.where(topic_id: message_ids.map { |message_id| message_id[topic_id_regexp, 1] }.compact, post_number: 1).pluck(:id)
      post_ids << EmailLog.where(message_id: message_ids).pluck(:post_id)
      post_ids << IncomingEmail.where(message_id: message_ids).pluck(:post_id)

      post_ids.flatten!
      post_ids.compact!
      post_ids.uniq!

      return if post_ids.empty?

      Post.where(id: post_ids).order(:created_at).last
    end

    def self.extract_references(references)
      if Array === references
        references
      elsif references.present?
        references.split(/[\s,]/).map { |r| r.tr("<>", "") }
      end
    end

    def likes
      @likes ||= Set.new ["+1", "<3", "❤", I18n.t('post_action_types.like.title').downcase]
    end

    def subscription_action_for(body, subject)
      return unless SiteSetting.unsubscribe_via_email
      if ([subject, body].compact.map(&:to_s).map(&:downcase) & ['unsubscribe']).any?
        :confirm_unsubscribe
      end
    end

    def post_action_for(body)
      PostActionType.types[:like] if likes.include?(body.strip.downcase)
    end

    def create_topic(options={})
      create_post_with_attachments(options)
    end

    def create_reply(options={})
      raise TopicNotFoundError if options[:topic].nil? || options[:topic].trashed?

      if post_action_type = post_action_for(options[:raw])
        create_post_action(options[:user], options[:post], post_action_type)
      else
        raise TopicClosedError if options[:topic].closed?
        options[:topic_id] = options[:post].try(:topic_id)
        options[:reply_to_post_number] = options[:post].try(:post_number)
        options[:is_group_message] = options[:topic].private_message? && options[:topic].allowed_groups.exists?
        create_post_with_attachments(options)
      end
    end

    def create_post_action(user, post, type)
      PostActionCreator.new(user, post).perform(type)
    rescue PostAction::AlreadyActed
      # it's cool, don't care
    rescue Discourse::InvalidAccess => e
      raise InvalidPostAction.new(e)
    end

    def attachments
      # strip blacklisted attachments (mostly signatures)
      @attachments ||= @mail.attachments.select do |attachment|
        attachment.content_type !~ SiteSetting.attachment_content_type_blacklist_regex &&
        attachment.filename !~ SiteSetting.attachment_filename_blacklist_regex
      end
    end

    def create_post_with_attachments(options={})
      # deal with attachments
      attachments.each do |attachment|
        tmp = Tempfile.new(["discourse-email-attachment", File.extname(attachment.filename)])
        begin
          # read attachment
          File.open(tmp.path, "w+b") { |f| f.write attachment.body.decoded }
          # create the upload for the user
          opts = { is_attachment_for_group_message: options[:is_group_message] }
          upload = UploadCreator.new(tmp, attachment.filename, opts).create_for(options[:user].id)
          if upload && upload.errors.empty?
            # try to inline images
            if attachment.content_type.start_with?("image/")
              if options[:raw][attachment.url]
                options[:raw].sub!(attachment.url, upload.url)
              elsif options[:raw][/\[image:.*?\d+[^\]]*\]/i]
                options[:raw].sub!(/\[image:.*?\d+[^\]]*\]/i, attachment_markdown(upload))
              else
                options[:raw] << "\n\n#{attachment_markdown(upload)}\n\n"
              end
            else
              options[:raw] << "\n\n#{attachment_markdown(upload)}\n\n"
            end
          end
        ensure
          tmp.try(:close!) rescue nil
        end
      end

      create_post(options)
    end

    def attachment_markdown(upload)
      if FileHelper.is_image?(upload.original_filename)
        "<img src='#{upload.url}' width='#{upload.width}' height='#{upload.height}'>"
      else
        "<a class='attachment' href='#{upload.url}'>#{upload.original_filename}</a> (#{number_to_human_size(upload.filesize)})"
      end
    end

    def create_post(options={})
      options[:via_email] = true
      options[:raw_email] = @raw_email

      # ensure posts aren't created in the future
      options[:created_at] ||= @mail.date
      if options[:created_at].nil?
        raise InvalidPost, "No post creation date found. Is the e-mail missing a Date: header?"
      end

      options[:created_at]   = DateTime.now if options[:created_at] > DateTime.now

      is_private_message = options[:archetype] == Archetype.private_message ||
                           options[:topic].try(:private_message?)

      # only add elided part in messages
      if options[:elided].present? && (SiteSetting.always_show_trimmed_content || is_private_message)
        options[:raw] << Email::Receiver.elided_html(options[:elided])
      end

      user = options.delete(:user)
      result = NewPostManager.new(user, options).perform

      raise InvalidPost, result.errors.full_messages.join("\n") if result.errors.any?

      if result.post
        @incoming_email.update_columns(topic_id: result.post.topic_id, post_id: result.post.id)
        if result.post.topic && result.post.topic.private_message?
          add_other_addresses(result.post.topic, user)
        end
      end

      result.post
    end

    def self.elided_html(elided)
      html =  "\n\n" << "<details class='elided'>" << "\n"
      html << "<summary title='#{I18n.t('emails.incoming.show_trimmed_content')}'>&#183;&#183;&#183;</summary>" << "\n"
      html << elided << "\n"
      html << "</details>" << "\n"
      html
    end

    def add_other_addresses(topic, sender)
      %i(to cc bcc).each do |d|
        if @mail[d] && @mail[d].address_list && @mail[d].address_list.addresses
          @mail[d].address_list.addresses.each do |address_field|
            begin
              address_field.decoded
              email = address_field.address.downcase
              display_name = address_field.display_name.try(:to_s)
              next unless email["@"]
              if should_invite?(email)
                user = find_or_create_user(email, display_name)
                if user && can_invite?(topic, user)
                  topic.topic_allowed_users.create!(user_id: user.id)
                  topic.add_small_action(sender, "invited_user", user.username)
                end
                # cap number of staged users created per email
                if @staged_users_created > SiteSetting.maximum_staged_users_per_email
                  topic.add_moderator_post(sender, I18n.t("emails.incoming.maximum_staged_user_per_email_reached"))
                  return
                end
              end
            rescue ActiveRecord::RecordInvalid
              # don't care if user already allowed
            end
          end
        end
      end
    end

    def should_invite?(email)
      email !~ Email::Receiver.reply_by_email_address_regex &&
      email !~ group_incoming_emails_regex &&
      email !~ category_email_in_regex
    end

    def can_invite?(topic, user)
      !topic.topic_allowed_users.where(user_id: user.id).exists? &&
      !topic.topic_allowed_groups.where("group_id IN (SELECT group_id FROM group_users WHERE user_id = ?)", user.id).exists?
    end

  end

end
