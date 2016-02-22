# `dropdb bbpress`
# `createdb bbpress`
# `bundle exec rake db:migrate`

require 'mysql2'
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

BB_PRESS_DB = ENV['BBPRESS_DB'] || "bbpress"
DB_TABLE_PREFIX = "wp_"

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
              user_registered created_at
         FROM #{table_name 'users'}", cache_rows: false)

    puts '', "creating users"

    create_users(users_results) do |u|
      ActiveSupport::HashWithIndifferentAccess.new(u)
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
        mapped[:custom_fields] = {import_id: post["id"], import_slug: post["post_name"]}

        if post["post_type"] == "topic"
          mapped[:category] = category_id_from_imported_category_id(post["post_parent"])
          mapped[:title] = CGI.unescapeHTML post["post_title"]
          mapped[:slug] = post["post_name"]
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

        skip ? nil : mapped
      end
    end
  end

end

ImportScripts::Bbpress.new.perform
