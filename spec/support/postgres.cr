require "spec"
require "postgres"

module PostgresSpec
  # A superuser (or database owner) session on a scratch database. Every
  # live example works inside its own tables and drops them.
  URL = ENV.fetch("POSTGRES_URL", "postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable")

  # Whether a server answers at URL, probed once with a real session.
  AVAILABLE = begin
    Postgres::Connection.new(URL, connect_timeout: 1.second, read_timeout: 2.seconds).close
    true
  rescue
    false
  end

  # Opens a connection to URL (with *options* passed to `Connection.new`),
  # yields it and closes it.
  def self.connect(**options, & : Postgres::Connection ->) : Nil
    conn = Postgres::Connection.new(URL, **options)
    begin
      yield conn
    ensure
      conn.close
    end
  end
end

# An example that needs the live server at `PostgresSpec::URL`; pending
# when none answers.
def pending_postgres(description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
  if PostgresSpec::AVAILABLE
    it(description, file, line, end_line, &block)
  else
    pending("#{description} [no postgres server at #{PostgresSpec::URL}]", file, line, end_line)
  end
end

# An example that needs the URL in environment variable *env* (a role
# using one particular authentication method); pending when unset.
def pending_postgres_env(env : String, description = "assert", file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block : String ->)
  if url = ENV[env]?.presence
    it(description, file, line, end_line) { block.call(url) }
  else
    pending("#{description} [set #{env}]", file, line, end_line)
  end
end
