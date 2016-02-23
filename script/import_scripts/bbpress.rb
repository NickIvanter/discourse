# `dropdb bbpress`
# `createdb bbpress`
# `bundle exec rake db:migrate`

require 'mysql2'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

BB_PRESS_DB = ENV['BBPRESS_DB'] || "bbpress"
DB_TABLE_PREFIX = "wp_"
AVATARS_BASE_PATH = "/vagrant/bbpress_avatars/"

class ImportScripts::Bbpress < ImportScripts::Base

  def initialize
    super

    @client = Mysql2::Client.new(
      host: "localhost",
      username: "root",
      #password: "password",
      database: BB_PRESS_DB
    )
    puts "loading post mappings..."
    @post_number_map = {}
    Post.pluck(:id, :post_number).each do |post_id, post_number|
      @post_number_map[post_id] = post_number
    end

    @topic_subscriptions_map = {}
  end

  def created_post(post)
    @post_number_map[post.id] = post.post_number
    super
  end

  def table_name(name)
    DB_TABLE_PREFIX + name
  end

  def execute
    users_results = @client.query("
       SELECT id,
              display_name name,
              user_email email,
              user_registered created_at,
              topic_subscriptions,
              forum_subscriptions,
              user_avatar
         FROM #{table_name 'users'} u
LEFT OUTER JOIN (select user_id, meta_value as topic_subscriptions from #{table_name 'usermeta'} where meta_key like'%_bbp_subscriptions') um
             ON u.id = um.user_id
LEFT OUTER JOIN (select user_id, meta_value as forum_subscriptions from #{table_name 'usermeta'} where meta_key like'%_bbp_forum_subscriptions') um1
             ON u.id = um1.user_id
LEFT OUTER JOIN (select user_id, meta_value as user_avatar from #{table_name 'usermeta'} where meta_key = 'basic_user_avatar') um2
             ON u.id = um2.user_id
                                  cache_rows: false)

    puts '', "creating users"

    create_users(users_results) do |u|

      new_user_data = ActiveSupport::HashWithIndifferentAccess.new(u)

      # Save topic subscriptions into a temporary hash, because we can't subscribe the newly created user
      # to any topics yet because no topics have been imported at this point. So we'll subscribe him later.
      topic_subscriptions = new_user_data.delete(:topic_subscriptions)
      @topic_subscriptions_map[new_user_data[:id]] = topic_subscriptions if topic_subscriptions

      forum_subscriptions = new_user_data.delete(:forum_subscriptions)
      user_avatar = new_user_data.delete(:user_avatar)

      new_user_data.merge(
        {
          post_create_action: proc do |user|
            # Do not ever send any emails unless the user was subscribed to a bbPress forum
            if forum_subscriptions.nil?
              user.user_option.update_columns(email_always: false,
                                              email_digests: false,
                                              email_direct: false,
                                              email_private_messages: false)
            else
              # Do nothing, let the site-wide default email settings be applied
            end

            if user_avatar
              # We do not use the specific value (url) of user_avatar stored in the Wordpress database. We simply
              # assume that the avatar file name is <user_numeric_id>.jpg, which is the case when using the
              # Basic User Avatars Wordpress plugin.
              begin
                filename = new_user_data[:id].to_s + '.jpg'
                path = AVATARS_BASE_PATH + filename
                upload = @uploader.create_upload(user.id, path, filename)

                if upload.present? && upload.persisted?
                  user.import_mode = false
                  user.create_user_avatar
                  user.import_mode = true
                  user.user_avatar.update(custom_upload_id: upload.id)
                  user.update(uploaded_avatar_id: upload.id)
                else
                  puts "Failed to upload avatar for user #{user.username}: #{path}"
                  puts upload.errors.inspect if upload
                end
              rescue SystemCallError => err
                Rails.logger.error("Could not import avatar for user #{user.username}: #{err.message}")
              end
            end
          end
        }
      )
    end


    puts '', '', "creating categories"

    create_categories(@client.query("SELECT id, post_title, post_parent from #{table_name 'posts'} WHERE post_type = 'forum' AND post_title != '' ORDER BY post_parent")) do |c|
      result = {id: c['id'], name: c['post_title']}
      parent_id = c['post_parent'].to_i
      if parent_id > 0
        result[:parent_category_id] = category_id_from_imported_category_id(parent_id)
      end
      result
    end

    import_posts
    migrate_subscriptions
  end

  def migrate_subscriptions
    puts "", "migrating topic subscriptions"

    total_count = @topic_subscriptions_map.count
    progress_count = 0

    @topic_subscriptions_map.each do |imported_user_id, list_of_topics|
      user_id = user_id_from_imported_user_id(imported_user_id)
      list_of_topics.to_s.split(",").each do |imported_topic_id|
        topic = topic_lookup_from_imported_post_id(imported_topic_id.to_i)
        next if topic.nil?
        TopicUser.change(user_id, topic[:topic_id], notification_level: TopicUser.notification_levels[:watching])
      end
      progress_count += 1
      print_status(progress_count, total_count)
    end
  end

  def import_posts
    puts '', "creating topics and posts"

    total_count = @client.query("
      SELECT count(*) count
        FROM #{table_name 'posts'}
       WHERE post_status <> 'spam'
         AND post_type IN ('topic', 'reply')").first['count']

    batch_size = 1000

    batches(batch_size) do |offset|
      results = @client.query("
                   SELECT id,
                          post_author,
                          post_date,
                          post_content,
                          post_title,
                          post_type,
                          post_name,
                          reply_to,
                          post_parent,
                          author_ip,
                          anonymous_name,
                          anonymous_email
                     FROM #{table_name 'posts'} p
          LEFT OUTER JOIN (select post_id, meta_value as reply_to from #{table_name 'postmeta'} where meta_key='_bbp_reply_to') pm
                       ON p.ID = pm.post_id
          LEFT OUTER JOIN (select post_id, meta_value as author_ip from #{table_name 'postmeta'} where meta_key='_bbp_author_ip') pm1
                       ON p.ID = pm1.post_id
          LEFT OUTER JOIN (select post_id, meta_value as anonymous_name from #{table_name 'postmeta'} where meta_key='_bbp_anonymous_name') pm2
                       ON p.ID = pm2.post_id
          LEFT OUTER JOIN (select post_id, meta_value as anonymous_email from #{table_name 'postmeta'} where meta_key='_bbp_anonymous_email') pm3
                       ON p.ID = pm3.post_id
                    WHERE post_status = 'publish'
                      AND post_type IN ('topic', 'reply')
                 ORDER BY id
                    LIMIT #{batch_size}
                   OFFSET #{offset}", cache_rows: true)

      break if results.size < 1

      next if all_records_exist? :posts, results.map {|p| p["id"].to_i}

      # Discourse import scripts require that each imported user have an ID from the external system. This is fine
      # when we are importing "regular" Wordpress users, but presents a small issue when we want to create new user
      # in the middle of the import process, which we want to do when importing "anonymous" posts. We want to create
      # Discourse users for the authors of those posts.
      # So, we are going to assign "fake" import IDs to those users. We begin with the arbitrary ID of 65535 and
      # go down from there, HOPING that it will not intersect with the IDs of the existing Wordpress users, which
      # are numbered from 1 upward.
      anonymous_user_fake_import_id = 65535

      create_posts(results, total: total_count, offset: offset) do |post|
        skip = false
        mapped = {}

        mapped[:id] = post["id"]

        if post["post_author"] == 0
          anonymous_users = Array.new
          anonymous_users[0] = {
            name: post["anonymous_name"],
            email: post["anonymous_email"],
            created_at: post["post_date"],
            id: anonymous_user_fake_import_id
          }
          create_users(anonymous_users) do |u|
            ActiveSupport::HashWithIndifferentAccess.new(u)
          end
          post["post_author"] = anonymous_user_fake_import_id
          anonymous_user_fake_import_id -= 1
        end

        mapped[:user_id] = user_id_from_imported_user_id(post["post_author"]) || find_user_by_import_id(post["post_author"]).try(:id) || -1
        mapped[:raw] = post["post_content"]
        if mapped[:raw]
          mapped[:raw] = mapped[:raw].gsub("<pre><code>", "```\n").gsub("</code></pre>", "\n```")
        end
        mapped[:created_at] = post["post_date"]
        mapped[:custom_fields] = {import_id: post["id"]}

        if post["post_type"] == "topic"
          mapped[:category] = category_id_from_imported_category_id(post["post_parent"])
          mapped[:title] = CGI.unescapeHTML post["post_title"]
        else
          parent = topic_lookup_from_imported_post_id(post["post_parent"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
            reply_to_post_id = post_id_from_imported_post_id(post["reply_to"]) if post["reply_to"]
            mapped[:reply_to_post_number] = @post_number_map[reply_to_post_id] if @post_number_map[reply_to_post_id]
          else
            puts "Skipping #{post["id"]}: #{post["post_content"][0..40]}"
            skip = true
          end
        end

        # Do not subscribe post authors to any topics by default
        mapped[:auto_track] = false

        # Create permalinks for the bbPress topics' URLs
        mapped[:post_create_action] = proc do |topic|
          next unless post["post_type"] == "topic"
          next if post["post_name"].blank?
          next if Permalink.where(url: post["post_name"], topic_id: topic.topic_id).exists?

          Permalink.create(url: post["post_name"], topic_id: topic.topic_id)
        end

        skip ? nil : mapped
      end
    end
  end

end

ImportScripts::Bbpress.new.perform
