require "rails_helper"
require "email/receiver"

describe Email::Receiver do

  before do
    SiteSetting.email_in = true
    SiteSetting.reply_by_email_address = "reply+%{reply_key}@bar.com"
  end

  def email(email_name)
    fixture_file("emails/#{email_name}.eml")
  end

  def process(email_name)
    Email::Receiver.new(email(email_name)).process
  end

  it "raises an EmptyEmailError when 'mail_string' is blank" do
    expect { Email::Receiver.new(nil) }.to raise_error(Email::Receiver::EmptyEmailError)
    expect { Email::Receiver.new("") }.to raise_error(Email::Receiver::EmptyEmailError)
  end

  it "raises an NoMessageIdError when 'mail_string' is not an email" do
    expect { Email::Receiver.new("wat") }.to raise_error(Email::Receiver::NoMessageIdError)
  end

  it "raises an NoMessageIdError when 'mail_string' is missing the message_id" do
    expect { Email::Receiver.new(email(:missing_message_id)) }.to raise_error(Email::Receiver::NoMessageIdError)
  end

  it "raises an AutoGeneratedEmailError when the mail is auto generated" do
    expect { process(:auto_generated_precedence) }.to raise_error(Email::Receiver::AutoGeneratedEmailError)
    expect { process(:auto_generated_header) }.to raise_error(Email::Receiver::AutoGeneratedEmailError)
  end

  it "raises a NoBodyDetectedError when the body is blank" do
    expect { process(:no_body) }.to raise_error(Email::Receiver::NoBodyDetectedError)
  end

  it "raises an InactiveUserError when the sender is inactive" do
    Fabricate(:user, email: "inactive@bar.com", active: false)
    expect { process(:inactive_sender) }.to raise_error(Email::Receiver::InactiveUserError)
  end

  it "raises a BlockedUserError when the sender has been blocked" do
    Fabricate(:user, email: "blocked@bar.com", blocked: true)
    expect { process(:blocked_sender) }.to raise_error(Email::Receiver::BlockedUserError)
  end

  skip "doesn't raise an InactiveUserError when the sender is staged" do
    Fabricate(:user, email: "staged@bar.com", active: false, staged: true)
    expect { process(:staged_sender) }.not_to raise_error
  end

  it "raises a BadDestinationAddress when destinations aren't matching any of the incoming emails" do
    expect { process(:bad_destinations) }.to raise_error(Email::Receiver::BadDestinationAddress)
  end

  context "reply" do

    let(:reply_key) { "4f97315cc828096c9cb34c6f1a0d6fe8" }
    let(:user) { Fabricate(:user, email: "discourse@bar.com") }
    let(:topic) { create_topic(user: user) }
    let(:post) { create_post(topic: topic, user: user) }
    let!(:email_log) { Fabricate(:email_log, reply_key: reply_key, user: user, topic: topic, post: post) }

    it "raises a ReplyUserNotMatchingError when the email address isn't matching the one we sent the notification to" do
      expect { process(:reply_user_not_matching) }.to raise_error(Email::Receiver::ReplyUserNotMatchingError)
    end

    it "raises a TopicNotFoundError when the topic was deleted" do
      topic.update_columns(deleted_at: 1.day.ago)
      expect { process(:reply_user_matching) }.to raise_error(Email::Receiver::TopicNotFoundError)
    end

    it "raises a TopicClosedError when the topic was closed" do
      topic.update_columns(closed: true)
      expect { process(:reply_user_matching) }.to raise_error(Email::Receiver::TopicClosedError)
    end

    it "raises an InvalidPost when there was an error while creating the post" do
      expect { process(:too_small) }.to raise_error(Email::Receiver::InvalidPost)
    end

    it "raises an InvalidPost when there are too may mentions" do
      SiteSetting.max_mentions_per_post = 1
      Fabricate(:user, username: "user1")
      Fabricate(:user, username: "user2")
      expect { process(:too_many_mentions) }.to raise_error(Email::Receiver::InvalidPost)
    end

    it "raises an InvalidPostAction when they aren't allowed to like a post" do
      topic.update_columns(archived: true)
      expect { process(:like) }.to raise_error(Email::Receiver::InvalidPostAction)
    end

    it "works" do
      expect { process(:text_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is a text reply :)")
      expect(topic.posts.last.via_email).to eq(true)
      expect(topic.posts.last.cooked).not_to match(/<br/)

      expect { process(:html_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is a <b>HTML</b> reply ;)")

      expect { process(:hebrew_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("שלום! מה שלומך היום?")

      expect { process(:chinese_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("您好！ 你今天好吗？")
    end

    it "prefers text over html" do
      expect { process(:text_and_html_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is the *text* part.")
    end

    it "removes the 'on <date>, <contact> wrote' quoting line" do
      expect { process(:on_date_contact_wrote) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is the actual reply.")
    end

    it "removes the 'Previous Replies' marker" do
      expect { process(:previous_replies) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This will not include the previous discussion that is present in this email.")
    end

    it "handles multiple paragraphs" do
      expect { process(:paragraphs) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("Do you like liquorice?\n\nI really like them. One could even say that I am *addicted* to liquorice. Anf if\nyou can mix it up with some anise, then I'm in heaven ;)")
    end

    describe 'Unsubscribing via email' do
      let(:last_email) { ActionMailer::Base.deliveries.last }

      describe 'unsubscribe_subject.eml' do
        it 'sends an email asking the user to confirm the unsubscription' do
          expect { process("unsubscribe_subject") }.to change { ActionMailer::Base.deliveries.count }.by(1)
          expect(last_email.to.length).to eq 1
          expect(last_email.from.length).to eq 1
          expect(last_email.from).to include "noreply@#{Discourse.current_hostname}"
          expect(last_email.to).to include "discourse@bar.com"
          expect(last_email.subject).to eq I18n.t(:"unsubscribe_mailer.subject_template").gsub("%{site_title}", SiteSetting.title)
        end

        it 'does nothing unless unsubscribe_via_email is turned on' do
          SiteSetting.stubs("unsubscribe_via_email").returns(false)
          before_deliveries = ActionMailer::Base.deliveries.count
          expect { process("unsubscribe_subject") }.to raise_error { Email::Receiver::BadDestinationAddress }
          expect(before_deliveries).to eq ActionMailer::Base.deliveries.count
        end
      end

      describe 'unsubscribe_body.eml' do
        it 'sends an email asking the user to confirm the unsubscription' do
          expect { process("unsubscribe_body") }.to change { ActionMailer::Base.deliveries.count }.by(1)
          expect(last_email.to.length).to eq 1
          expect(last_email.from.length).to eq 1
          expect(last_email.from).to include "noreply@#{Discourse.current_hostname}"
          expect(last_email.to).to include "discourse@bar.com"
          expect(last_email.subject).to eq I18n.t(:"unsubscribe_mailer.subject_template").gsub("%{site_title}", SiteSetting.title)
        end

        it 'does nothing unless unsubscribe_via_email is turned on' do
          SiteSetting.stubs(:unsubscribe_via_email).returns(false)
          before_deliveries = ActionMailer::Base.deliveries.count
          expect { process("unsubscribe_body") }.to raise_error { Email::Receiver::InvalidPost }
          expect(before_deliveries).to eq ActionMailer::Base.deliveries.count
        end
      end
    end

    it "handles inline reply" do
      expect { process(:inline_reply) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("> WAT <https://bar.com/users/wat> November 28\n>\n> This is the previous post.\n\nAnd this is *my* reply :+1:")
    end

    it "retrieves the first part of multiple replies" do
      expect { process(:inline_mixed_replies) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("> WAT <https://bar.com/users/wat> November 28\n>\n> This is the previous post.\n\nAnd this is *my* reply :+1:\n\n> This is another post.\n\nAnd this is **another** reply.")
    end

    it "strips mobile/webmail signatures" do
      expect { process(:iphone_signature) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is not the signature you're looking for.")
    end

    it "strips 'original message' context" do
      expect { process(:original_message) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to eq("This is a reply :)")
    end

    it "supports attached images" do
      expect { process(:no_body_with_image) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to match(/<img/)

      expect { process(:inline_image) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to match(/Before\s+<img.+\s+After/m)
    end

    it "supports attachments" do
      SiteSetting.authorized_extensions = "txt"
      expect { process(:attached_txt_file) }.to change { topic.posts.count }
      expect(topic.posts.last.raw).to match(/text\.txt/)
    end

    it "supports liking via email" do
      expect { process(:like) }.to change(PostAction, :count)
    end

    it "ensures posts aren't dated in the future" do
      expect { process(:from_the_future) }.to change { topic.posts.count }
      expect(topic.posts.last.created_at).to be_within(1.minute).of(DateTime.now)
    end

  end

  context "new message to a group" do

    let!(:group) { Fabricate(:group, incoming_email: "team@bar.com") }

    it "handles encoded display names" do
      expect { process(:encoded_display_name) }.to change(Topic, :count)

      topic = Topic.last
      expect(topic.title).to eq("I need help")
      expect(topic.private_message?).to eq(true)
      expect(topic.allowed_groups).to include(group)

      user = topic.user
      expect(user.staged).to eq(true)
      expect(user.username).to eq("random.name")
      expect(user.name).to eq("Случайная Имя")
    end

    it "handles email with no subject" do
      expect { process(:no_subject) }.to change(Topic, :count)
      expect(Topic.last.title).to eq("Incoming email from some@one.com")
    end

    it "invites everyone in the chain but emails configured as 'incoming' (via reply, group or category)" do
      expect { process(:cc) }.to change(Topic, :count)
      emails = Topic.last.allowed_users.pluck(:email)
      expect(emails.size).to eq(3)
      expect(emails).to include("someone@else.com", "discourse@bar.com", "wat@bar.com")
    end

    it "associates email replies using both 'In-Reply-To' and 'References' headers" do
      expect { process(:email_reply_1) }.to change(Topic, :count)

      topic = Topic.last

      expect { process(:email_reply_2) }.to change { topic.posts.count }
      expect { process(:email_reply_3) }.to change { topic.posts.count }

      # Why 5 when we only processed 3 emails?
      #   - 3 of them are indeed "regular" posts generated from the emails
      #   - The 2 others are "small action" posts automatically added because
      #     we invited 2 users (two@foo.com and three@foo.com)
      expect(topic.posts.count).to eq(5)

      # trash all but the 1st post
      topic.ordered_posts[1..-1].each(&:trash!)

      expect { process(:email_reply_4) }.to change { topic.posts.count }
    end

  end

  context "new topic in a category" do

    let!(:category) { Fabricate(:category, email_in: "category@bar.com", email_in_allow_strangers: false) }

    it "raises a StrangersNotAllowedError when 'email_in_allow_strangers' is disabled" do
      expect { process(:new_user) }.to raise_error(Email::Receiver::StrangersNotAllowedError)
    end

    it "raises an InsufficientTrustLevelError when user's trust level isn't enough" do
      Fabricate(:user, email: "existing@bar.com", trust_level: 3)
      SiteSetting.email_in_min_trust = 4
      expect { process(:existing_user) }.to raise_error(Email::Receiver::InsufficientTrustLevelError)
    end

    it "works" do
      user = Fabricate(:user, email: "existing@bar.com", trust_level: SiteSetting.email_in_min_trust)
      group = Fabricate(:group)

      group.add(user)
      group.save

      category.set_permissions(group => :create_post)
      category.save

      # raises an InvalidAccess when the user doesn't have the privileges to create a topic
      expect { process(:existing_user) }.to raise_error(Discourse::InvalidAccess)

      category.update_columns(email_in_allow_strangers: true)

      # allows new user to create a topic
      expect { process(:new_user) }.to change(Topic, :count)
    end

  end

end
