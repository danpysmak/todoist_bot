defmodule TodoistBot.CaptureTest do
  use TodoistBot.DataCase, async: false
  import Mox
  import Plug.Conn
  alias TodoistBot.{Capture, Attachment, Interaction, User, Processor, Inbox}
  alias TodoistBot.Telegram.API, as: Telegram
  alias TodoistBot.Todoist.API, as: Todoist

  setup :verify_on_exit!

  setup do
    user =
      Repo.insert!(%User{
        telegram_id: 222,
        last_chat_id: 222,
        access_token: "test-access",
        auth_state: "222.state"
      })

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          calls: [],
          comment_fail: false,
          upload_fail: false,
          sync_fail: false,
          bytes: "file bytes",
          size: 10,
          file_path: "documents/test.pdf"
        }
      end)

    stub(Telegram.Mock, :request, fn req -> Req.request(req, plug: &server(&1, state)) end)

    stub(Todoist.Mock, :request, fn req ->
      Req.request(req, plug: &server(&1, state), retry_delay: fn _ -> 0 end)
    end)

    on_exit(fn ->
      Application.delete_env(:todoist_bot, :owner_telegram_id)
      Application.delete_env(:todoist_bot, :max_attachment_bytes)
    end)

    %{user: user, state: state}
  end

  defp message_update(extra, id \\ 1) do
    %{
      "update_id" => id,
      "message" =>
        Map.merge(
          %{
            "message_id" => id,
            "chat" => %{"id" => 222, "type" => "private"},
            "from" => %{"id" => 222}
          },
          extra
        )
    }
  end

  defp interaction(extra, user, id \\ 1) do
    {:ok, i} = Interaction.from_update(message_update(extra, id))
    %{i | user: user}
  end

  defp file(extra \\ %{}), do: Map.merge(%{"file_id" => "file-id", "file_size" => 10}, extra)
  defp calls(state), do: Agent.get(state, &Enum.reverse(&1.calls))
  defp commands(state), do: for({:sync, c} <- calls(state), do: c)

  defp uploads(state),
    do: for({:upload, bytes, name, mime} <- calls(state), do: {bytes, name, mime})

  defp server(conn, state) do
    cond do
      conn.request_path == "/api/v1/sync" ->
        {:ok, body, conn} = read_body(conn)
        [command] = URI.decode_query(body)["commands"] |> Jason.decode!()
        Agent.update(state, &%{&1 | calls: [{:sync, command} | &1.calls]})

        fail =
          Agent.get(state, &(&1.sync_fail or (&1.comment_fail and command["type"] == "note_add")))

        if fail do
          conn |> put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
        else
          Req.Test.json(conn, %{
            "sync_status" => %{command["uuid"] => "ok"},
            "temp_id_mapping" => %{command["temp_id"] => "real-" <> command["temp_id"]}
          })
        end

      conn.request_path == "/api/v1/uploads" ->
        {:ok, body, conn} = read_body(conn)
        name = get_req_header(conn, "x-file-name") |> hd()
        mime = get_req_header(conn, "content-type") |> hd()
        Agent.update(state, &%{&1 | calls: [{:upload, body, name, mime} | &1.calls]})

        if Agent.get(state, & &1.upload_fail) do
          conn |> put_status(403) |> Req.Test.json(%{"error" => "plan or scope"})
        else
          Req.Test.json(conn, %{
            "file_url" => "https://files.todoist.com/test/file.pdf",
            "file_name" => name,
            "file_type" => mime
          })
        end

      String.ends_with?(conn.request_path, "/getFile") ->
        s = Agent.get(state, & &1)

        Req.Test.json(conn, %{
          "ok" => true,
          "result" => %{"file_path" => s.file_path, "file_size" => s.size}
        })

      String.starts_with?(conn.request_path, "/file/") ->
        send_resp(conn, 200, Agent.get(state, & &1.bytes))

      String.ends_with?(conn.request_path, "/sendMessage") ->
        {:ok, body, conn} = read_body(conn)
        Agent.update(state, &%{&1 | calls: [{:telegram, Jason.decode!(body)} | &1.calls]})
        Req.Test.json(conn, %{"ok" => true, "result" => true})

      true ->
        flunk("Unexpected request path")
    end
  end

  for type <- ["document", "audio", "voice", "video", "video_note", "animation", "sticker"] do
    test "#{type} original bytes are uploaded and attached", %{user: user, state: state} do
      type = unquote(type)
      assert {:ok, _} = Capture.run(interaction(%{type => file()}, user))
      assert [{"file bytes", _, _}] = uploads(state)

      assert [
               %{"type" => "item_add"},
               %{
                 "type" => "note_add",
                 "args" => %{
                   "file_attachment" => %{"file_url" => "https://files.todoist.com/test/file.pdf"}
                 }
               }
             ] = commands(state)

      assert length(Repo.all(Capture)) == 2
    end
  end

  test "largest resolution photo wins, caption and forwarded content survive", %{
    user: user,
    state: state
  } do
    photo = [
      %{"file_id" => "small", "width" => 20, "height" => 20},
      %{"file_id" => "big", "width" => 200, "height" => 200}
    ]

    assert {:ok, %{id: "big"}} = Attachment.extract(%{"photo" => photo})

    assert {:ok, _} =
             Capture.run(
               interaction(
                 %{
                   "photo" => photo,
                   "caption" => "Проверить 📎",
                   "forward_origin" => %{"type" => "hidden_user"}
                 },
                 user
               )
             )

    assert [
             %{"args" => %{"content" => "Проверить 📎"}},
             %{"args" => %{"content" => "Проверить 📎"}}
           ] = commands(state)
  end

  test "album shares one task and retains late captions", %{user: user, state: state} do
    assert {:ok, task} =
             Capture.run(interaction(%{"document" => file(), "media_group_id" => "album"}, user))

    assert {:ok, ^task} =
             Capture.run(
               interaction(
                 %{
                   "document" => file(),
                   "media_group_id" => "album",
                   "caption" => "Later caption"
                 },
                 user,
                 2
               )
             )

    assert Enum.count(commands(state), &(&1["type"] == "item_add")) == 1
    assert Enum.count(commands(state), &(&1["type"] == "note_add")) == 2
    assert List.last(commands(state))["args"]["content"] == "Later caption"
  end

  test "replayed update causes no repeated upload/task/comment", %{user: user, state: state} do
    i = interaction(%{"document" => file()}, user)
    assert {:ok, task} = Capture.run(i)
    assert {:ok, ^task} = Capture.run(i)
    assert length(commands(state)) == 2
    assert length(uploads(state)) == 1
  end

  test "comment failure retries UUID then resumes uploaded checkpoint", %{
    user: user,
    state: state
  } do
    Agent.update(state, &%{&1 | comment_fail: true})
    i = interaction(%{"document" => file()}, user)
    assert {:error, :todoist_failed} = Capture.run(i)
    attempted = for(c <- commands(state), c["type"] == "note_add", do: c["uuid"])
    assert length(attempted) == 3
    assert length(Enum.uniq(attempted)) == 1
    Agent.update(state, &%{&1 | comment_fail: false})
    assert {:ok, _} = Capture.run(i)
    assert length(uploads(state)) == 1
    assert Enum.count(commands(state), &(&1["type"] == "item_add")) == 1
    assert List.last(commands(state))["uuid"] == hd(attempted)
  end

  test "upload error leaves task and reports failure, retry keeps task", %{
    user: user,
    state: state
  } do
    Agent.update(state, &%{&1 | upload_fail: true})
    i = interaction(%{"document" => file()}, user)
    assert {:error, :permission} = Capture.run(i)
    assert length(commands(state)) == 1
    Agent.update(state, &%{&1 | upload_fail: false})
    assert {:ok, _} = Capture.run(i)
    assert Enum.count(commands(state), &(&1["type"] == "item_add")) == 1
  end

  test "oversize metadata and actual streamed bytes are bounded", %{user: user, state: state} do
    Application.put_env(:todoist_bot, :max_attachment_bytes, 5)
    assert {:error, :too_large} = Capture.run(interaction(%{"document" => file()}, user))
    assert uploads(state) == []
    Agent.update(state, &%{&1 | size: nil})
    assert {:error, :too_large} = Telegram.download("file")

    assert {:halt, {_, %{body: "", private: %{too_large: true}}}} =
             Telegram.collect({:data, "123456"}, {nil, %Req.Response{body: ""}})
  end

  test "filename Unicode preserved, traversal/control/header injection removed", %{
    user: user,
    state: state
  } do
    assert {:ok, _} =
             Capture.run(
               interaction(
                 %{
                   "document" =>
                     file(%{
                       "file_name" => "../счёт\r\n\".pdf",
                       "mime_type" => "application/pdf\r\nX: bad"
                     })
                 },
                 user
               )
             )

    assert [{_, name, "application/octet-stream"}] = uploads(state)
    assert String.contains?(name, "счёт")
    refute String.contains?(name, ["/", "\r", "\n", "\""])
  end

  test "unsafe Telegram paths rejected before any download", %{state: state} do
    for path <- [
          "../secret",
          "https://evil.test/file.pdf",
          "/etc/file.pdf",
          "files/a.pdf?secret=x",
          "files/%2e%2e.pdf"
        ] do
      Agent.update(state, &%{&1 | file_path: path})
      assert {:error, :download_failed} = Telegram.download("file")
    end
  end

  test "text-only task and long text preserve full message", %{user: user, state: state} do
    text = String.duplicate("界", 700)
    assert {:ok, _} = Capture.run(interaction(%{"text" => text}, user))
    assert [%{"args" => %{"content" => title, "description" => ^text}}] = commands(state)
    assert String.length(title) == 500
    assert uploads(state) == []
  end

  test "unsupported message does not create empty task and gives visible response", %{
    state: state
  } do
    assert {:ok, _} =
             Processor.process_message(
               message_update(%{"contact" => %{"phone_number" => "test"}})
             )

    assert commands(state) == []
    assert [{:telegram, %{"text" => "Unsupported message:" <> _}}] = calls(state)
  end

  test "actual owner/private access enforced before user DB load", %{state: state} do
    Application.put_env(:todoist_bot, :owner_telegram_id, 999)
    assert :ignored = Processor.process_message(message_update(%{"text" => "hello"}))
    assert :ok = Inbox.enqueue(message_update(%{"text" => "hello"}))
    assert Repo.all(Inbox) == []
    assert calls(state) == []
  end

  test "durable ingress deduplicates before worker runs", %{state: _state} do
    u = message_update(%{"document" => file()})
    assert :ok = Inbox.enqueue(u)
    assert :ok = Inbox.enqueue(u)
    assert [%{payload: ^u, done: false}] = Repo.all(Inbox)
  end

  test "retry reply references original identity rather than creating new task", %{
    user: user,
    state: state
  } do
    original = message_update(%{"document" => file()})["message"]
    assert {:ok, task} = Capture.run(interaction(%{"document" => file()}, user))

    assert {:ok, ^task} =
             Capture.run(
               interaction(%{"text" => "/retry", "reply_to_message" => original}, user, 2)
             )

    assert length(commands(state)) == 2
    assert {:error, :invalid_retry} = Capture.run(interaction(%{"text" => "/retry"}, user, 3))
  end

  test "caption and forwarded command-like messages are captured, not executed", %{state: state} do
    assert {:ok, _} =
             Processor.process_message(
               message_update(%{"document" => file(), "caption" => "/logout"})
             )

    assert {:ok, _} =
             Processor.process_message(
               message_update(
                 %{"text" => "/help", "forward_origin" => %{"type" => "hidden_user"}},
                 2
               )
             )

    assert Enum.count(commands(state), &(&1["type"] == "item_add")) == 2
    assert Enum.any?(commands(state), &(&1["args"]["content"] == "/logout"))
    assert Enum.any?(commands(state), &(&1["args"]["content"] == "/help"))
    assert Repo.get!(User, 222).access_token == "test-access"
  end

  test "concurrent album items serialize to one task", %{user: user, state: state} do
    test_pid = self()

    jobs =
      for id <- [1, 2],
          do:
            Task.async(fn ->
              allow(Telegram.Mock, test_pid, self())
              allow(Todoist.Mock, test_pid, self())

              Capture.run(
                interaction(%{"document" => file(), "media_group_id" => "concurrent"}, user, id)
              )
            end)

    assert [{:ok, task}, {:ok, task}] = Enum.map(jobs, &Task.await(&1, 10_000))
    assert Enum.count(commands(state), &(&1["type"] == "item_add")) == 1
    assert length(uploads(state)) == 2
  end

  test "unsupported captioned paid media is not silently reduced to text", %{
    user: user,
    state: state
  } do
    assert {:error, :unsupported} =
             Capture.run(interaction(%{"paid_media" => %{}, "caption" => "keep me"}, user))

    assert commands(state) == []
  end

  test "animation preferred over compatibility document; sticker defaults explicit" do
    assert {:ok, %{kind: "animation"}} =
             Attachment.extract(%{"animation" => file(), "document" => file()})

    for {meta, expected} <- [
          {%{}, "sticker.webp"},
          {%{"is_animated" => true}, "sticker.tgs"},
          {%{"is_video" => true}, "sticker.webm"}
        ] do
      assert {:ok, %{name: ^expected}} = Attachment.extract(%{"sticker" => file(meta)})
    end
  end
end
