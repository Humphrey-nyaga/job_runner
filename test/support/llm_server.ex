defmodule JobRunner.Test.LLMServer do
  @moduledoc """
  A real HTTP server that impersonates an OpenAI-compatible endpoint badly, on
  purpose.

  The `Mock` adapter proves the *engine* handles failures. This proves the
  *adapter* does — and the two are genuinely different concerns. Mock never
  exercises Req, JSON decoding, status handling, or socket timeouts, so an
  adapter bug would sail straight past it.

  A real Bandit server is used rather than `Req`'s `:plug` test option because
  some of the failures we care about only exist at the transport layer: a
  receive timeout is not something a plug can simulate, since a plug is invoked
  after the connection has already succeeded.
  """

  use Agent

  @doc "Start the server on a free port. Returns the base URL to point an adapter at."
  @spec start() :: String.t()
  def start do
    {:ok, _} = Agent.start_link(fn -> :ok_response end, name: __MODULE__)
    port = free_port()

    {:ok, _} =
      Bandit.start_link(
        plug: __MODULE__.Plug,
        port: port,
        scheme: :http,
        startup_log: false
      )

    "http://127.0.0.1:#{port}"
  end

  @doc """
  Choose what the next request receives.

  Each scenario reproduces one real failure mode of an LLM endpoint.
  """
  @spec scenario(atom() | {atom(), term()}) :: :ok
  def scenario(scenario), do: Agent.update(__MODULE__, fn _ -> scenario end)

  @doc false
  def current, do: Agent.get(__MODULE__, & &1)

  # Ask the OS for an unused port, then immediately release it. A short race
  # window exists, which is acceptable in a test helper and avoids depending on
  # Bandit internals to read back a :port 0 assignment.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      respond(conn, JobRunner.Test.LLMServer.current(), body)
    end

    # F-none: the happy path. Echoes the model back so tests can assert that
    # configuration actually reached the wire.
    defp respond(conn, :ok_response, body) do
      model = body |> Jason.decode!() |> Map.get("model")
      json(conn, 200, chat_envelope("hello from #{model}"))
    end

    defp respond(conn, {:ok_response, content}, _body) do
      json(conn, 200, chat_envelope(content))
    end

    # A reasoning model that spent its whole budget thinking: vLLM serving Qwen3
    # returns content:null with the chain-of-thought in a separate field.
    defp respond(conn, :reasoning_only, _body) do
      json(conn, 200, %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "reasoning" => "Here's a thinking process: let me consider..."
            },
            "finish_reason" => "length"
          }
        ]
      })
    end

    # Cut off by the token limit while producing real content.
    defp respond(conn, :truncated, _body) do
      json(conn, 200, %{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => ~s({"summary": "half a sen)},
            "finish_reason" => "length"
          }
        ]
      })
    end

    # F8: well-formed envelope, no usable content.
    defp respond(conn, :empty_content, _body), do: json(conn, 200, chat_envelope("   "))

    # F7: 200 with an envelope we cannot read. Happens for real when a proxy
    # returns its own page, or a server returns {"error": ...} with status 200.
    defp respond(conn, :no_choices, _body), do: json(conn, 200, %{"choices" => []})

    defp respond(conn, :wrong_shape, _body),
      do: json(conn, 200, %{"unexpected" => "envelope"})

    defp respond(conn, :not_json, _body) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html>gateway says hi</html>")
    end

    # F3–F6: status failures.
    defp respond(conn, {:status, status}, _body),
      do: json(conn, status, %{"error" => %{"message" => "boom"}})

    # F2: hold the connection open past the client's receive_timeout.
    defp respond(conn, {:sleep, ms}, _body) do
      Process.sleep(ms)
      json(conn, 200, chat_envelope("too late"))
    end

    # Echoes the parsed request body so tests can assert what was sent.
    defp respond(conn, :echo_request, body),
      do: json(conn, 200, chat_envelope(body))

    defp chat_envelope(content) do
      %{
        "id" => "chatcmpl-test",
        "object" => "chat.completion",
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => content}}
        ]
      }
    end

    defp json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(payload))
    end
  end
end
