require "logger"
require "uri"
require "pliny/utils"

begin
  require "sequel"
  require "sequel/extensions/migration"
  require "pliny/db_support"

  namespace :db do
    desc "Run database migrations"
    task :migrate do
      next if Dir["./db/migrate/*.rb"].empty?
      database_urls.each do |database_url|
        Pliny::DbSupport.run(database_url, $stdout) do |helper|
          helper.migrate
          puts "Migrated `#{name_from_uri(database_url)}`"
        end
      end
    end

    desc "Rollback last database migration"
    task :rollback do
      next if Dir["./db/migrate/*.rb"].empty?
      database_urls.each do |database_url|
        Pliny::DbSupport.run(database_url, $stdout) do |helper|
          helper.rollback
          puts "Rolled back `#{name_from_uri(database_url)}`"
        end
      end
    end

    desc "Seed the database with data"
    task :seed do
      if File.exist?('./db/seeds.rb')
        database_urls.each do |database_url|
          Sequel.connect(database_url)
          load 'db/seeds.rb'
        end
        disconnect
      end
    end

    desc "Create the database"
    task :create do
      database_urls.each do |database_url|
        db_name = name_from_uri(database_url)
        if Pliny::DbSupport.setup?(database_url)
          puts "Skipping `#{db_name}`, already exists"
        else
          admin_url = Pliny::DbSupport.admin_url(database_url)
          Pliny::DbSupport.run(admin_url) do |helper|
            helper.create(db_name)
            puts "Created `#{db_name}`"
          end
        end
      end
      disconnect
    end

    desc "Drop the database"
    task :drop do
      database_urls.each do |database_url|
        admin_url = Pliny::DbSupport.admin_url(database_url)
        db = Sequel.connect(admin_url)
        name = name_from_uri(database_url)
        db.run(%{DROP DATABASE IF EXISTS "#{name}"})
        puts "Dropped `#{name}`"
      end
      disconnect
    end

    namespace :schema do
      desc "Load the database schema"
      task :load do
        if File.exists?("./db/schema.sql")
          schema = File.read("./db/schema.sql")
          database_urls.each do |database_url|
            db = Sequel.connect(database_url)
            db.run(schema)
            puts "Loaded `#{name_from_uri(database_url)}`"
          end
          disconnect
        else
          puts "Skipped schema load, schema.sql not present"
        end
      end

      desc "Dump the database schema"
      task :dump do
        file = File.join("db", "schema.sql")
        database_url = database_urls.first
        `pg_dump -i -s -x -O -f #{file} #{database_url}`

        schema = File.read(file)
        # filter all COMMENT ON EXTENSION, only owners and the db
        # superuser can execute these, making it impossible to just
        # replay such statements in certain production databases
        schema.gsub!(/^COMMENT ON EXTENSION.*\n/, "")

        # add migrations used to compose this schema
        db = Sequel.connect(database_urls.first)
        if db.table_exists?(:schema_migrations)
          db[:schema_migrations].each do |migration|
            schema << db[:schema_migrations].insert_sql(migration) + ";\n"
          end
        end
        disconnect

        File.open(file, "w") { |f| f.puts schema }
        puts "Dumped `#{name_from_uri(database_url)}` to #{file}"
      end

      desc "Merges migrations into schema and removes them"
      task :merge => ["db:setup", "db:schema:dump"] do
        FileUtils.rm Dir["./db/migrate/*.rb"]
        puts "Removed migrations"
      end
    end

    desc "Setup the database"
    task :setup => [:drop, :create, "schema:load", :migrate, :seed]

    private

    def disconnect
      Sequel::DATABASES.each { |db| db.disconnect }
      Sequel::DATABASES.clear
    end

    def database_urls
      if ENV["DATABASE_URL"]
        [ENV["DATABASE_URL"]]
      else
        %w(.env .env.test).map { |env_file|
          env_path = "./#{env_file}"
          if File.exists?(env_path)
            Pliny::Utils.parse_env(env_path)["DATABASE_URL"]
          else
            nil
          end
        }.compact
      end
    end

    def name_from_uri(uri)
      URI.parse(uri).path[1..-1]
    end
  end

rescue LoadError
  puts "Couldn't load sequel. Skipping database tasks"
end
