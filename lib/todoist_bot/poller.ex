defmodule TodoistBot.Poller do
  @moduledoc "Acknowledge Telegram offsets only after durable inbox insertion."
  use GenServer
  alias TodoistBot.{Inbox, Telegram.API}
  def start_link(_token), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    send(self(), :poll)
    {:ok, nil}
  end

  def handle_info(:poll, offset) do
    next = poll(offset)
    Process.send_after(self(), :poll, if(next == offset, do: 2000, else: 0))
    {:noreply, next}
  end

  def poll(offset) do
    params = %{timeout: 20, allowed_updates: ["message", "callback_query"]}
    params = if offset, do: Map.put(params, :offset, offset), else: params

    case API.request("getUpdates", params) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} when is_list(updates) ->
        Enum.reduce_while(updates, offset, fn update, current ->
          case Inbox.enqueue(update) do
            :ok -> {:cont, max(current || 0, update["update_id"] + 1)}
            _ -> {:halt, current}
          end
        end)

      _ ->
        offset
    end
  end
end
