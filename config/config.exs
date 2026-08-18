# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :job_runner,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :job_runner, JobRunnerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: JobRunnerWeb.ErrorHTML, json: JobRunnerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: JobRunner.PubSub,
  live_view: [signing_salt: "MGpJwYDn"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  job_runner: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  job_runner: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# LLM provider. Defaults target the internal endpoint named in the brief; every
# value is overridable from the environment in config/runtime.exs, so switching
# providers never requires a code change (ADR-008).
config :job_runner, :llm,
  adapter: JobRunner.LLM.OpenAICompatible,
  # base_url / model / api_key are NOT set here. They are deployment values, and
  # they come from the provider profile in config/runtime.exs, which reads them
  # from namespaced environment variables (VLLM_BASE_URL, OPENAI_MODEL, ...).
  # Duplicating them here would mean the same literal in two files, with the
  # runtime one silently winning — worse than having it in one place.
  # Generous: the endpoint is shared and latency is variable by design.
  receive_timeout: 45_000,
  connect_timeout: 5_000,
  # Optional request fields. `nil` means "do not send this field at all" —
  # providers in this family disagree about which they accept.
  temperature: 0.2,
  # Completion budget. Sized against the 32,768-token context window:
  #
  #   prompt cap    24,000 bytes  ~=  6,000 tokens  (max_prompt_bytes)
  #   system prompt                     ~200 tokens
  #   completion                       4,096 tokens  (this setting)
  #   ------------------------------------------------
  #   worst case                     ~10,300 tokens  -- comfortably inside 32,768
  #
  # 1024 was too tight: an open-ended prompt ("tell me about accounting") wants
  # ~1,000 tokens on its own, and a reasoning model spends its budget thinking
  # before it answers anything at all.
  max_tokens: 4096,
  # vLLM and older OpenAI models: :max_tokens.
  # Newer OpenAI reasoning models: :max_completion_tokens.
  token_param: :max_tokens

# Job engine. See docs/DESIGN.md §8 for why each default is what it is.
config :job_runner, :jobs,
  # Deliberately small: the endpoint is shared, and concurrency past the point
  # where the *server* saturates only converts queueing delay into timeouts.
  max_concurrency: 4,
  # 1 initial attempt + 4 retries. Named "attempts", not "retries", to keep the
  # off-by-one visible rather than implicit.
  max_attempts: 5,
  # Backoff gaps: 500ms, 1s, 2s, 4s (±25% jitter), capped.
  backoff_base_ms: 500,
  backoff_max_ms: 30_000,
  backoff_jitter: 0.25,
  # Job deadline, distinct from the HTTP receive timeout: a wedged adapter or a
  # slow parse can blow past the latter (FMEA F12).
  job_timeout_ms: 60_000,
  # Admission backpressure — bounds the VM, where max_concurrency bounds the endpoint.
  max_pending_jobs: 10_000,
  max_prompt_bytes: 24_000,
  breaker_threshold: 5,
  breaker_cooldown_ms: 30_000,
  breaker_max_cooldown_ms: 300_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
