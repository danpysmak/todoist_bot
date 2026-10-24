defmodule TodoistBot.Access do
  @moduledoc "Check the actual sender, never forwarded origin or username."
  def allowed?(update) do
    {sender, chat} =
      case update do
        %{"callback_query" => %{"from" => from, "message" => %{"chat" => chat}}} -> {from, chat}
        %{"message" => %{"from" => from, "chat" => chat}} -> {from, chat}
        _ -> {%{}, %{}}
      end

    case Application.get_env(:todoist_bot, :owner_telegram_id) do
      nil ->
        is_integer(sender["id"]) and is_integer(chat["id"]) and chat["type"] in [nil, "private"]

      owner ->
        sender["id"] == owner and chat["id"] == owner and chat["type"] == "private"
    end
  end
end

defmodule TodoistBot.Inbox do
  @moduledoc "Durable ingress before Telegram acknowledgement; serialized worker resumes after restart."
  use GenServer
  use Ecto.Schema
  require Logger
  import Ecto.Query
  alias TodoistBot.Repo
  @primary_key {:key, :string, autogenerate: false}
  schema "incoming_updates" do
    field(:payload, :map)
    field(:done, :boolean, default: false)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    timestamps(type: :utc_datetime)
  end

  def enqueue(%{"update_id" => id} = update) when is_integer(id) do
    if TodoistBot.Access.allowed?(update) do
      key = "#{TodoistBot.Capture.namespace()}:#{id}"

      case Repo.insert(%__MODULE__{key: key, payload: update}, on_conflict: :nothing) do
        {:ok, _} -> :ok
        _ -> {:error, :storage}
      end
    else
      :ok
    end
  end

  def enqueue(_), do: :ok

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    Process.send_after(self(), :work, 1000)
    {:ok, nil}
  end

  def handle_info(:work, state) do
    work_once()
    Process.send_after(self(), :work, 1000)
    {:noreply, state}
  end

  def work_once do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    row =
      Repo.one(
        from(u in __MODULE__,
          where: u.done == false and (is_nil(u.next_attempt_at) or u.next_attempt_at <= ^now),
          order_by: [asc: u.inserted_at, asc: u.key],
          limit: 1
        )
      )

    if row do
      try do
        case TodoistBot.Processor.process_message(row.payload) do
          {:ok, %{status: status, body: %{"ok" => true}}} when status in 200..299 -> complete(row)
          :ignored -> complete(row)
          _ -> retry_later(row)
        end
      rescue
        _ -> retry_later(row)
      catch
        _, _ -> retry_later(row)
      end
    end

    :ok
  end

  defp retry_later(row) do
    attempts = row.attempts + 1

    if attempts >= 10 do
      Logger.error(
        "Telegram inbox update dead-lettered after 10 failed attempts; inspect pending/failed inbox counters"
      )

      row |> Ecto.Changeset.change(done: true, attempts: attempts) |> Repo.update!()
    else
      next =
        DateTime.utc_now()
        |> DateTime.add(min(attempts * 5, 60), :second)
        |> DateTime.truncate(:second)

      row |> Ecto.Changeset.change(attempts: attempts, next_attempt_at: next) |> Repo.update!()
    end
  end

  defp complete(row) do
    # Keep deduplication key, discard private message content after delivery.
    row |> Ecto.Changeset.change(done: true, payload: %{}) |> Repo.update!()
  end
end
