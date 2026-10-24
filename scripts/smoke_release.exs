# Offline production-release smoke test. All provider HTTP is replaced before application startup.
# Only synthetic, explicitly supplied environment values may be used with this test.
Req.default_options(plug: fn conn -> Req.Test.json(conn, %{"ok" => true, "result" => true}) end)
{:ok, _} = Application.ensure_all_started(:todoist_bot)
false = Keyword.fetch!(Application.fetch_env!(:todoist_bot, TodoistBot.Repo), :log)
:info = Logger.level()
port = Application.fetch_env!(:todoist_bot, :app_port)
{:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5000)

:ok =
  :gen_tcp.send(socket, "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

response =
  Stream.repeatedly(fn -> :gen_tcp.recv(socket, 0, 5000) end)
  |> Enum.reduce_while("", fn
    {:ok, bytes}, acc -> {:cont, acc <> bytes}
    {:error, :closed}, acc -> {:halt, acc}
    other, _ -> raise "HTTP smoke failed: #{inspect(other)}"
  end)

true = String.starts_with?(response, "HTTP/1.1 200")
true = String.ends_with?(response, "\r\n\r\nok")

# Fake data markers must never appear in captured production SQL/platform logs.
TodoistBot.Repo.insert!(%TodoistBot.User{
  telegram_id: 1,
  access_token: "SYNTHETIC_SECRET_MARKER",
  auth_state: "SYNTHETIC_STATE_MARKER"
})

:ok =
  TodoistBot.Inbox.enqueue(%{
    "update_id" => 1,
    "message" => %{
      "message_id" => 1,
      "chat" => %{"id" => 1, "type" => "private"},
      "from" => %{"id" => 1},
      "text" => "SYNTHETIC_PAYLOAD_MARKER"
    }
  })

IO.puts(
  "OFFLINE RELEASE SMOKE PASSED: actual HTTP /healthz=200, migrations applied, SQL logging disabled, inherited PORT preserved; providers mocked"
)

Application.stop(:todoist_bot)
