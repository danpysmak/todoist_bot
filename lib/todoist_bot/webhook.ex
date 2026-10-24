defmodule TodoistBot.Webhook do
  use Plug.Builder

  alias TodoistBot.Telegram.API

  plug(:check_webhook_enabled)
  plug(:check_token)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    length: 1_000_000,
    json_decoder: Jason
  )

  plug(:parse_update)
  plug(:invoke_processor)
  plug(:respond)

  def delete_webhook() do
    with {:ok, %{status: 200}} <- API.request("deleteWebhook", %{}) do
      :ignore
    end
  end

  def setup_webhook do
    host = Application.fetch_env!(:todoist_bot, :app_host)
    path = Application.fetch_env!(:todoist_bot, :webhook_token)
    max_connections = Application.get_env(:todoist_bot, :webhook_max_connections, 1)
    url = host <> path <> "/"

    with {:ok, %{status: 200, body: %{"ok" => true}}} <-
           API.request("setWebhook", %{
             url: url,
             max_connections: max_connections,
             secret_token: path,
             allowed_updates: ["message", "callback_query"]
           }) do
      :ignore
    end
  end

  defp check_webhook_enabled(conn, _opts) do
    if Application.get_env(:todoist_bot, :use_webhook) != "true" do
      conn
      |> send_resp(404, "Page not found")
      |> halt()
    else
      conn
    end
  end

  defp check_token(conn, _opts) do
    secret = Application.fetch_env!(:todoist_bot, :webhook_token)

    if conn.params["token"] == secret and
         get_req_header(conn, "x-telegram-bot-api-secret-token") == [secret] do
      conn
    else
      conn
      |> send_resp(404, "Page not found")
      |> halt()
    end
  end

  defp parse_update(conn, _opts), do: assign(conn, :update, conn.body_params)

  defp invoke_processor(%{assigns: %{update: %{} = update}} = conn, _opts) do
    case TodoistBot.Inbox.enqueue(update) do
      :ok -> conn
      {:error, _} -> conn |> send_resp(503, "Retry later") |> halt()
    end
  end

  defp respond(conn, _opts) do
    send_resp(conn, 200, "true")
  end
end
