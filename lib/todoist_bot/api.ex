defmodule TodoistBot.Api do
  use Plug.Router
  alias TodoistBot.{User, Repo}
  alias TodoistBot.Todoist.API
  import Ecto.Query
  @scope "data:read_write"
  # Never log request paths: OAuth codes and webhook secrets are private.
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} -> send_resp(conn, 200, "ok")
      _ -> send_resp(conn, 503, "unavailable")
    end
  end

  get "/authorize" do
    conn = fetch_query_params(conn)
    state = conn.query_params["uuid"]

    user =
      if is_binary(state), do: Repo.one(from(u in User, where: u.auth_state == ^state)), else: nil

    if user && allowed_owner?(user) do
      query =
        URI.encode_query(
          client_id: Application.fetch_env!(:todoist_bot, :todoist_app_client_id),
          scope: @scope,
          state: state
        )

      conn
      |> put_resp_header("location", "https://todoist.com/oauth/authorize?" <> query)
      |> send_resp(301, "You're being redirected...")
    else
      send_resp(conn, 400, "Invalid authorization request")
    end
  end

  get "/authorization/finish" do
    conn = fetch_query_params(conn)

    with nil <- conn.query_params["error"],
         code when is_binary(code) and code != "" <- conn.query_params["code"],
         state when is_binary(state) and state != "" <- conn.query_params["state"],
         {:ok, user} <- complete_authorization(code, state) do
      Task.Supervisor.start_child(TodoistBot.TaskSupervisor, fn ->
        user.last_chat_id
        |> TodoistBot.Interaction.notification(
          "You have been successfully authorized! Send text or a file to create an Inbox task."
        )
        |> TodoistBot.Processor.send_notification()
      end)

      send_resp(conn, 200, "You have been successfully authorized.")
    else
      _ ->
        send_resp(
          conn,
          400,
          "Authorization failed. Request a fresh authorization link from the bot."
        )
    end
  end

  post("/:token/", to: TodoistBot.Webhook)
  match(_, do: send_resp(conn, 404, "Resource not found"))

  defp allowed_owner?(user) do
    owner = Application.get_env(:todoist_bot, :owner_telegram_id)
    is_nil(owner) or owner == user.telegram_id
  end

  defp complete_authorization(code, state) do
    :global.trans({{__MODULE__, state}, self()}, fn ->
      with %User{} = user <- Repo.one(from(u in User, where: u.auth_state == ^state)),
           true <- allowed_owner?(user),
           {:ok, %{status: 200, body: %{"access_token" => token}}} <- API.get_access_token(code) do
        user
        |> User.changeset(%{
          auth_code: nil,
          access_token: token,
          auth_state: User.new_state(user).auth_state
        })
        |> Repo.update()
      else
        _ -> {:error, :authorization}
      end
    end)
  end
end
