import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :job_runner, JobRunnerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "k9TZaJCjmsiWObvC7kycwDwtzRT7NDQLnHxFnYe+QQsXebGbmu6/kRgxcGHTq6Um",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests never touch the network: the Mock adapter satisfies the same behaviour.
config :job_runner, :llm,
  adapter: JobRunner.LLM.Mock,
  base_url: "http://localhost:0",
  model: "mock-model",
  api_key: "test",
  receive_timeout: 200,
  connect_timeout: 200

# Each test starts its own job subsystem; see JobRunner.Application.jobs_subsystem/0.
config :job_runner, start_jobs: false
