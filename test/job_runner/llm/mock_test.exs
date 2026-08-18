defmodule JobRunner.LLM.MockTest do
  @moduledoc """
  The Mock is test infrastructure, so it gets tests of its own. A silently
  broken double would make every engine test that depends on it meaningless —
  green for the wrong reason, which is worse than red.
  """

  use ExUnit.Case, async: false

  alias JobRunner.LLM
  alias JobRunner.LLM.{Error, Mock}

  setup do
    start_supervised!(Mock)
    :ok
  end

  defp chat, do: Mock.chat(LLM.messages("hi"), [])

  test "returns scripted entries in order" do
    Mock.script([{:ok, "first"}, {:ok, "second"}, {:ok, "third"}])

    assert {:ok, "first"} = chat()
    assert {:ok, "second"} = chat()
    assert {:ok, "third"} = chat()
  end

  test "the last entry is sticky, so 'always fails' is a one-element script" do
    # This is why the engine can be asked to exhaust a budget without the test
    # having to predict how many attempts that will take.
    Mock.script([{:error, Error.timeout()}])

    for _ <- 1..10, do: assert({:error, %Error{class: :timeout}} = chat())
  end

  test "fails twice then succeeds — the canonical retry scenario" do
    Mock.script([
      {:error, Error.timeout()},
      {:error, Error.http_status(503, "unavailable")},
      {:ok, "third time lucky"}
    ])

    assert {:error, %Error{class: :timeout}} = chat()
    assert {:error, %Error{class: :http_status, code: 503}} = chat()
    assert {:ok, "third time lucky"} = chat()
    # Sticky: further calls keep succeeding.
    assert {:ok, "third time lucky"} = chat()
  end

  test "records calls so attempt budgets can be asserted" do
    Mock.script([{:ok, "x"}])
    assert Mock.call_count() == 0

    chat()
    chat()

    assert Mock.call_count() == 2
    assert [{messages, _opts}, _] = Mock.calls()
    assert [%{role: :user, content: "hi"}] = messages
  end

  test "{:sleep, ms, entry} delays before answering, for deadline tests" do
    Mock.script([{:sleep, 50, {:ok, "slow"}}])

    {elapsed_us, {:ok, "slow"}} = :timer.tc(&chat/0)
    assert elapsed_us >= 45_000
  end

  test "{:raise, msg} raises, for crash-isolation tests" do
    Mock.script([{:raise, "boom"}])

    assert_raise RuntimeError, "boom", &chat/0
  end

  test "concurrent callers never take the same script entry" do
    Mock.script([{:ok, "a"}, {:ok, "b"}, {:ok, "c"}, {:ok, "d"}, {:ok, "sticky"}])

    results =
      1..4
      |> Task.async_stream(fn _ -> chat() end, max_concurrency: 4)
      |> Enum.map(fn {:ok, {:ok, text}} -> text end)
      |> Enum.sort()

    # get_and_update is atomic, so four parallel callers get four distinct entries.
    assert results == ["a", "b", "c", "d"]
  end

  test "satisfies the LLM behaviour, so the engine cannot tell it apart" do
    assert LLM in Mock.__info__(:attributes)[:behaviour]
  end
end
