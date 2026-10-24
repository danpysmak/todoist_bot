defmodule TodoistBot.RecoveryTest do
  use TodoistBot.DataCase, async: false
  import Mox
  import Plug.Test
  import Plug.Conn
  alias TodoistBot.{Inbox, User, Capture}
  alias TodoistBot.Telegram.API, as: Telegram
  alias TodoistBot.Todoist.API, as: Todoist
  setup :verify_on_exit!

  setup do
    on_exit(fn -> Application.delete_env(:todoist_bot, :owner_telegram_id) end)
    :ok
  end

  defp callback do
    %{
      "update_id" => 100,
      "callback_query" => %{
        "id" => "logout-1",
        "data" => "/logout.confirm.yes",
        "from" => %{"id" => 222},
        "message" => %{"message_id" => 99, "chat" => %{"id" => 222, "type" => "private"}}
      }
    }
  end

  defp message(id, text) do
    %{
      "update_id" => id,
      "message" => %{
        "message_id" => id,
        "text" => text,
        "from" => %{"id" => 222},
        "chat" => %{"id" => 222, "type" => "private"}
      }
    }
  end

  test "logout completion drains inbox and later commands are not starved" do
    Repo.insert!(%User{telegram_id: 222, access_token: "old-token"})

    stub(Telegram.Mock, :request, fn _ ->
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    :ok = Inbox.enqueue(callback())
    :ok = Inbox.enqueue(message(101, "/help"))
    :ok = Inbox.work_once()
    assert Repo.get(User, 222) == nil
    :ok = Inbox.work_once()
    assert Enum.all?(Repo.all(Inbox), & &1.done)
    assert Enum.all?(Repo.all(Inbox), &(&1.payload == %{}))
  end

  test "failed logout notification cannot wipe a later reauthorization on replay" do
    Repo.insert!(%User{telegram_id: 222, access_token: "old-token"})
    stub(Telegram.Mock, :request, fn _ -> {:ok, %Req.Response{status: 503}} end)
    :ok = Inbox.enqueue(callback())
    :ok = Inbox.work_once()
    assert Repo.get(User, 222) == nil
    Repo.insert!(%User{telegram_id: 222, access_token: "new-token"})
    row = Repo.one(Inbox)
    assert row.attempts == 1
    row |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()

    stub(Telegram.Mock, :request, fn _ ->
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    :ok = Inbox.work_once()
    assert Repo.get(User, 222).access_token == "new-token"
    assert Repo.one(Inbox).done
  end

  test "poison notification backs off, next command runs, ten failures dead-letter" do
    stub(Telegram.Mock, :request, fn req ->
      if req.options.json.text =~ "/help -" do
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      else
        {:ok, %Req.Response{status: 403, body: %{"ok" => false}}}
      end
    end)

    :ok = Inbox.enqueue(message(100, "not authorized"))
    :ok = Inbox.enqueue(message(101, "/help"))
    :ok = Inbox.work_once()
    :ok = Inbox.work_once()
    failed = Repo.get!(Inbox, "#{Capture.namespace()}:100")
    assert failed.attempts == 1
    assert Repo.get!(Inbox, "#{Capture.namespace()}:101").done
    failed |> Ecto.Changeset.change(attempts: 9, next_attempt_at: nil) |> Repo.update!()
    :ok = Inbox.work_once()
    assert %{done: true, attempts: 10, payload: %{"message" => _}} = Repo.get!(Inbox, failed.key)
  end

  test "upload 401 clears invalid token and returns reauthorization button" do
    Repo.insert!(%User{telegram_id: 222, access_token: "expired", auth_state: "222.state"})
    key = "#{Capture.namespace()}:222:222:message:1"
    Repo.insert!(%Capture{key: key, task_id: "existing-task", title: "file"})

    stub(Todoist.Mock, :request, fn req ->
      assert req.url.path == "api/v1/uploads"
      {:ok, %Req.Response{status: 401}}
    end)

    stub(Telegram.Mock, :request, fn req ->
      case req.url.path do
        "bot{token}/getFile" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"ok" => true, "result" => %{"file_path" => "files/test.pdf"}}
           }}

        "/file/botmytoken/files/test.pdf" ->
          {:ok, %Req.Response{status: 200, body: "bytes"}}

        "bot{token}/sendMessage" ->
          assert req.options.json.reply_markup.inline_keyboard != []
          {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end
    end)

    u = message(1, "file") |> put_in(["message", "document"], %{"file_id" => "id"})
    assert {:ok, _} = TodoistBot.Processor.process_message(u)
    assert Repo.get!(User, 222).access_token == nil
    assert Repo.get!(Capture, key).task_id == "existing-task"
  end

  test "OAuth invalid state is rejected without token exchange; health checks DB" do
    Repo.insert!(%User{telegram_id: 222, auth_state: "222.correct"})
    expect(Todoist.Mock, :request, 0, fn _ -> flunk("Must not exchange unknown state") end)

    for query <- [
          "code=x&state=222.wrong",
          "code=x",
          "state=222.correct",
          "error=access_denied&state=222.correct"
        ] do
      assert %{status: 400} =
               conn(:get, "/authorization/finish?" <> query) |> TodoistBot.Api.call([])
    end

    assert %{status: 200, resp_body: "ok"} = conn(:get, "/healthz") |> TodoistBot.Api.call([])
  end

  test "OAuth successful consent consumes state and rejects replay" do
    user = Repo.insert!(%User{telegram_id: 222, auth_state: "222.correct", last_chat_id: 222})
    Application.put_env(:todoist_bot, :todoist_app_client_secret, "test-client")

    expect(Todoist.Mock, :request, fn _ ->
      {:ok, %Req.Response{status: 200, body: %{"access_token" => "authorized-token"}}}
    end)

    stub(Telegram.Mock, :request, fn _ ->
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    assert %{status: 200} =
             conn(:get, "/authorization/finish?code=x&state=" <> user.auth_state)
             |> TodoistBot.Api.call([])

    assert Repo.get!(User, 222).access_token == "authorized-token"
    refute Repo.get!(User, 222).auth_state == user.auth_state

    assert %{status: 400} =
             conn(:get, "/authorization/finish?code=x&state=" <> user.auth_state)
             |> TodoistBot.Api.call([])
  end

  test "webhook needs path and secret header, persists before response, deduplicates" do
    body = Jason.encode!(message(1, "hello"))

    request = fn header ->
      c =
        conn(:post, "/secret_token/", body) |> put_req_header("content-type", "application/json")

      c = if header, do: put_req_header(c, "x-telegram-bot-api-secret-token", header), else: c
      TodoistBot.Api.call(c, [])
    end

    assert request.(nil).status == 404
    assert request.("wrong").status == 404
    assert request.("secret_token").status == 200
    assert request.("secret_token").status == 200
    assert [%{payload: %{"message" => %{"text" => "hello"}}, done: false}] = Repo.all(Inbox)
  end

  test "poller advances offset only for persisted updates" do
    expect(Telegram.Mock, :request, fn req ->
      assert req.options.json.offset == 99

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"ok" => true, "result" => [message(100, "hi"), message(101, "hello")]}
       }}
    end)

    assert TodoistBot.Poller.poll(99) == 102
    assert length(Repo.all(Inbox)) == 2
  end
end
