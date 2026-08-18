import Config

# --- Load .env --------------------------------------------------------------
#
# Elixir has no built-in dotenv support, so without this the file is inert: it
# only takes effect if you remember to `set -a && . ./.env && set +a` first.
# That is a bad trap, because shell exports outlive the edit — sourcing sets
# variables but never *unsets* them, so commenting a line out and re-sourcing
# leaves the old value in the environment until you close the terminal.
#
# Loading it here means editing `.env` and restarting is enough, which is what
# anyone reasonably expects.
#
# Precedence: an explicitly exported variable WINS over the file. That keeps
# one-off overrides working —
#
#     MAX_CONCURRENCY=16 mix phx.server
#
# — and matches how dotenv behaves everywhere else. Skipped in :test, where
# config/test.exs is authoritative and a stray .env must never influence a run.
if config_env() != :test do
  env_file = Path.expand("../.env", __DIR__)

  if File.exists?(env_file) do
    loaded =
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)

            value =
              value
              |> String.trim()
              |> String.replace(~r/\A"(.*)"\z/s, "\\1")
              |> String.replace(~r/\A'(.*)'\z/s, "\\1")

            # Only fill in what the shell has not already set.
            if System.get_env(key) do
              []
            else
              System.put_env(key, value)
              [key]
            end

          _ ->
            []
        end
      end)

    if loaded != [] do
      IO.puts("[config] loaded #{length(loaded)} vars from .env: #{Enum.join(loaded, ", ")}")
    end
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/job_runner start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :job_runner, JobRunnerWeb.Endpoint, server: true
end

config :job_runner, JobRunnerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# --- LLM provider selection -------------------------------------------------
#
# Runtime, not compile time: the same build can be pointed at the internal vLLM
# endpoint, at OpenAI, or at a local Ollama without recompiling. Only keys that
# are actually set in the environment override the defaults in config.exs, so
# partial overrides (say, just LLM_BASE_URL) behave sensibly.
#
# Off-VPN development uses OpenAI:
#     LLM_BASE_URL=https://api.openai.com  LLM_MODEL=gpt-5.5  OPENAI_API_KEY=sk-...
if config_env() != :test do
  maybe_int = fn
    nil -> nil
    value -> String.to_integer(value)
  end

  # --- Engine tuning --------------------------------------------------------
  #
  # Runtime, so a demo can be reconfigured without editing source. The two most
  # useful in practice:
  #
  #   MAX_CONCURRENCY=16     the ceiling is conservative because the brief's
  #                          endpoint is shared; against your own key it need
  #                          not be
  #   BREAKER_THRESHOLD=999  effectively disables the circuit breaker, which is
  #                          how you demonstrate jobs burning their attempt
  #                          budgets and dead-lettering during a real outage.
  #                          With the breaker on they correctly stay :pending.
  jobs_overrides =
    [
      max_concurrency: maybe_int.(System.get_env("MAX_CONCURRENCY")),
      max_attempts: maybe_int.(System.get_env("MAX_ATTEMPTS")),
      job_timeout_ms: maybe_int.(System.get_env("JOB_TIMEOUT_MS")),
      max_pending_jobs: maybe_int.(System.get_env("MAX_PENDING_JOBS")),
      backoff_base_ms: maybe_int.(System.get_env("BACKOFF_BASE_MS")),
      breaker_threshold: maybe_int.(System.get_env("BREAKER_THRESHOLD")),
      breaker_cooldown_ms: maybe_int.(System.get_env("BREAKER_COOLDOWN_MS")),
      breaker_max_cooldown_ms: maybe_int.(System.get_env("BREAKER_MAX_COOLDOWN_MS"))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  if jobs_overrides != [] do
    config :job_runner,
           :jobs,
           Keyword.merge(Application.get_env(:job_runner, :jobs, []), jobs_overrides)
  end

  # --- Provider profiles ------------------------------------------------------
  #
  # A profile carries the PROTOCOL DIALECT only — facts about how a provider's
  # API is shaped, which are properties of that API and therefore code:
  #
  #   OpenAI    requires max_completion_tokens, rejects an explicit temperature
  #             on newer models, and rejects unknown body fields outright
  #   vLLM      uses max_tokens and accepts chat_template_kwargs, which is how
  #             Qwen3's thinking mode is disabled
  #
  # DEPLOYMENT VALUES — host, model name, credentials — are never written here.
  # They come from namespaced environment variables so that pointing at a
  # different vLLM box, or a different model on the same box, needs no code
  # change. The fallbacks below exist only so a fresh clone runs with no .env at
  # all; every one is overridable, and .env.example ships them as the documented
  # path.
  provider = System.get_env("LLM_PROVIDER", "vllm")

  # Single source of fallbacks, deliberately in one table rather than scattered
  # through the profiles. Values match the brief; change them via env, not here.
  fallback = %{
    "vllm" => %{base_url: "http://192.168.84.7:8001", model: "Qwen3.6-35B-A3B"},
    "openai" => %{base_url: "https://api.openai.com", model: "gpt-5.5"}
  }

  provider_env = fn suffix, default ->
    System.get_env("#{String.upcase(provider)}_#{suffix}") || default
  end

  provider_profile =
    case provider do
      "vllm" ->
        [
          base_url: provider_env.("BASE_URL", fallback["vllm"].base_url),
          model: provider_env.("MODEL", fallback["vllm"].model),
          # vLLM does not check the key, but an empty string is rejected by some
          # proxies, so a non-empty placeholder is the safe default.
          api_key: System.get_env("VLLM_API_KEY", "not-required"),
          token_param: :max_tokens,
          temperature: 0.2,
          # Qwen3 is a reasoning model; without this it spends the whole budget
          # thinking and returns content:null.
          chat_template_kwargs: %{enable_thinking: false}
        ]

      "openai" ->
        [
          base_url: provider_env.("BASE_URL", fallback["openai"].base_url),
          model: provider_env.("MODEL", fallback["openai"].model),
          api_key: System.get_env("OPENAI_API_KEY"),
          token_param: :max_completion_tokens,
          # Newer OpenAI models reject an explicit temperature, and reject
          # unknown fields outright — so chat_template_kwargs must NOT be sent.
          temperature: nil,
          chat_template_kwargs: nil
        ]

      other ->
        raise """
        Invalid LLM_PROVIDER=#{inspect(other)}. Expected "vllm", "openai", or unset.
        """
    end

  llm_overrides =
    [
      adapter: System.get_env("LLM_ADAPTER") && Module.concat([System.get_env("LLM_ADAPTER")]),
      base_url: System.get_env("LLM_BASE_URL"),
      model: System.get_env("LLM_MODEL"),
      api_key: System.get_env("LLM_API_KEY") || System.get_env("OPENAI_API_KEY"),
      receive_timeout: maybe_int.(System.get_env("LLM_RECEIVE_TIMEOUT_MS")),
      max_tokens: maybe_int.(System.get_env("LLM_MAX_TOKENS")),
      token_param:
        System.get_env("LLM_TOKEN_PARAM") && String.to_atom(System.get_env("LLM_TOKEN_PARAM")),
      temperature:
        case System.get_env("LLM_TEMPERATURE") do
          nil -> nil
          "none" -> nil
          value -> String.to_float(value)
        end,
      chat_template_kwargs:
        case System.get_env("LLM_ENABLE_THINKING") do
          nil ->
            nil

          "true" ->
            %{enable_thinking: true}

          "false" ->
            %{enable_thinking: false}

          value ->
            raise """
            Invalid LLM_ENABLE_THINKING=#{inspect(value)}.
            Expected true, false, or an unset value.
            """
        end
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> then(fn overrides ->
      if System.get_env("LLM_TEMPERATURE") == "none" do
        Keyword.put(overrides, :temperature, nil)
      else
        overrides
      end
    end)

  # Profile first, explicit variables second — so a profile gives you a working
  # baseline and any single LLM_* var still wins over it.
  resolved = Keyword.merge(provider_profile, llm_overrides)

  # Print the RESOLVED target, not just which variables were read.
  #
  # "loaded 4 vars from .env" answers the wrong question. What anyone actually
  # wants to know is which endpoint and model are in force after three layers of
  # precedence have been applied — especially since config.exs already defaults
  # to the internal endpoint, so the local model runs correctly with nothing set
  # at all. This is also the only place an incoherent combination (an OpenAI
  # model name against the vLLM host, say) becomes visible.
  effective = Keyword.merge(Application.get_env(:job_runner, :llm, []), resolved)

  IO.puts(
    "[config] LLM -> #{effective[:base_url]} model=#{effective[:model]} " <>
      "token_param=#{inspect(effective[:token_param])} " <>
      "thinking=#{if effective[:chat_template_kwargs], do: "off", else: "default"} " <>
      "key=#{if effective[:api_key] in [nil, "", "not-required"], do: "none", else: "set"}"
  )

  if resolved != [] do
    existing = Application.get_env(:job_runner, :llm, [])
    merged = Keyword.merge(existing, resolved)

    # A profile may deliberately set a key to nil to mean "do not send this".
    # Keyword.merge keeps the nil, and the adapter omits nil fields, so this is
    # exactly the behaviour we want — but it must survive the merge, hence no
    # nil-rejection here.
    config :job_runner, :llm, merged
  end
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :job_runner, JobRunnerWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/job_runner_web/router\.ex$",
        ~r"lib/job_runner_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :job_runner, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :job_runner, JobRunnerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :job_runner, JobRunnerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :job_runner, JobRunnerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
