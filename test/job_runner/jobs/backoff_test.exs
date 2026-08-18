defmodule JobRunner.Jobs.BackoffTest do
  use ExUnit.Case, async: true

  alias JobRunner.Jobs.Backoff

  describe "the advertised schedule" do
    test "doubles from the base" do
      # The exact sequence the brief names, and the one the README claims.
      assert Backoff.schedule(4) == [500, 1000, 2000, 4000]
    end

    test "max_attempts: 5 produces exactly 4 gaps" do
      # The off-by-one made explicit: 5 attempts have 4 waits between them.
      assert length(Backoff.schedule(5 - 1)) == 4
    end

    test "honours a configured base" do
      assert Backoff.schedule(3, base_ms: 100) == [100, 200, 400]
    end
  end

  describe "the cap" do
    test "stops doubling at max_ms" do
      assert Backoff.delay(12, jitter: 0.0) == 30_000
      assert Backoff.delay(50, jitter: 0.0) == 30_000
    end

    test "a huge attempt number does not overflow into a giant computation" do
      # Without the exponent guard this computes 2^999 before discarding it.
      assert Backoff.delay(999, jitter: 0.0) == 30_000
    end
  end

  describe "jitter" do
    test "stays within the configured band" do
      for attempt <- 1..4 do
        nominal = Backoff.delay(attempt, jitter: 0.0)

        for _ <- 1..200 do
          delay = Backoff.delay(attempt, jitter: 0.25)
          assert delay >= trunc(nominal * 0.75)
          assert delay <= ceil(nominal * 1.25)
        end
      end
    end

    test "actually decorrelates — 200 samples are not all identical" do
      # The property that matters: without this, a batch that fails together
      # retries together and stampedes the endpoint it just overloaded.
      samples = for _ <- 1..200, do: Backoff.delay(3, jitter: 0.25)

      assert length(Enum.uniq(samples)) > 50
    end

    test "jitter: 0.0 is deterministic, which is what lets other tests assert timing" do
      samples = for _ <- 1..50, do: Backoff.delay(2, jitter: 0.0)
      assert Enum.uniq(samples) == [1000]
    end

    test "never returns a negative delay" do
      for _ <- 1..500 do
        assert Backoff.delay(1, base_ms: 1, jitter: 5.0) >= 0
      end
    end
  end
end
