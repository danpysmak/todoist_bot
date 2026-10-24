defmodule TodoistBot.Capture do
  @moduledoc "Single-instance, durable, resumable task and attachment writes. Sync command UUIDs prevent duplicate writes."
  use Ecto.Schema
  alias TodoistBot.{Attachment, Repo}
  alias TodoistBot.Telegram.API, as: Telegram
  alias TodoistBot.Todoist.API, as: Todoist
  @primary_key {:key, :string, autogenerate: false}
  schema "captures" do
    field(:task_id, :string)
    field(:attachment, :map)
    field(:comment_id, :string)
    field(:title, :string)
  end

  def namespace do
    Application.fetch_env!(:todoist_bot, :bot_token) |> String.split(":") |> hd()
  end

  def uuid(key) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _::binary>> =
      :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  def run(interaction) do
    original = get_in(interaction.request.raw || %{}, ["message"]) || %{}
    retry? = interaction.request.text == "/retry" and interaction.request.is_command
    reply = original["reply_to_message"] || %{}
    valid_retry? = retry? and get_in(reply, ["from", "id"]) == interaction.user.telegram_id
    message = if valid_retry?, do: reply, else: original
    media = Attachment.extract(message)

    text =
      if valid_retry?,
        do: message["text"] || message["caption"] || "",
        else: interaction.request.text || ""

    cond do
      retry? and not valid_retry? ->
        {:error, :invalid_retry}

      media == :none and
          (String.trim(text) == "" or
             Enum.any?(
               [
                 "paid_media",
                 "story",
                 "contact",
                 "location",
                 "venue",
                 "poll",
                 "game",
                 "dice",
                 "invoice",
                 "passport_data"
               ],
               &(not is_nil(message[&1]))
             )) ->
        {:error, :unsupported}

      not is_integer(message["message_id"]) ->
        {:error, :invalid_message}

      true ->
        owner = interaction.user.telegram_id

        key =
          "#{namespace()}:#{owner}:#{interaction.request.chat_id}:" <>
            if(message["media_group_id"],
              do: "album:#{message["media_group_id"]}",
              else: "message:#{message["message_id"]}"
            )

        :global.trans({{__MODULE__, key}, self()}, fn ->
          capture(interaction, message, media, text, key)
        end)
    end
  end

  defp capture(i, message, media, text, key) do
    filename =
      case media do
        {:ok, file} -> file.name
        _ -> "Telegram message"
      end

    title = if String.trim(text) == "", do: filename, else: text
    task = load(key, title)
    item = load(key <> ":file:#{message["message_id"]}", title)
    token = i.user.access_token

    with {:ok, task} <- ensure_task(task, token),
         {:ok, _item} <- ensure_file(item, task, media, text, token) do
      {:ok, task.task_id}
    end
  end

  defp load(key, title) do
    Repo.insert!(%__MODULE__{key: key, title: title}, on_conflict: :nothing)
    Repo.get!(__MODULE__, key)
  end

  defp save(row, changes), do: row |> Ecto.Changeset.change(changes) |> Repo.update()

  defp ensure_task(%{task_id: id} = row, _) when is_binary(id), do: {:ok, row}

  defp ensure_task(row, token) do
    args = %{content: String.slice(row.title, 0, 500)}

    args =
      if String.length(row.title) > 500, do: Map.put(args, :description, row.title), else: args

    with {:ok, id} <- sync(token, row.key <> ":task", "item_add", args) do
      save(row, task_id: id)
    end
  end

  defp ensure_file(row, _, :none, _, _), do: {:ok, row}
  defp ensure_file(%{comment_id: id} = row, _, _, _, _) when is_binary(id), do: {:ok, row}

  defp ensure_file(row, task, {:ok, file}, text, token) do
    with :ok <- Attachment.size_ok(file.size),
         {:ok, row} <- ensure_upload(row, file, token),
         {:ok, comment_id} <-
           sync(token, row.key <> ":comment", "note_add", %{
             item_id: task.task_id,
             content:
               if(String.trim(text) == "", do: "Telegram attachment: #{file.name}", else: text),
             file_attachment: row.attachment
           }) do
      save(row, comment_id: comment_id)
    end
  end

  defp ensure_upload(%{attachment: %{}} = row, _, _), do: {:ok, row}

  defp ensure_upload(row, file, token) do
    with {:ok, bytes} <- Telegram.download(file.id),
         {:ok, %{status: status, body: %{"file_url" => url} = attachment}} when status in 200..299 <-
           Todoist.request("api/v1/uploads", token,
             method: :post,
             body: bytes,
             headers: [{"content-type", file.mime}, {"x-file-name", file.name}],
             retry: false
           ),
         %URI{scheme: "https", host: "files.todoist.com"} <- URI.parse(url) do
      attachment =
        Map.take(attachment, [
          "file_url",
          "file_name",
          "file_type",
          "file_size",
          "resource_type",
          "upload_state",
          "image",
          "image_width",
          "image_height"
        ])
        |> Map.put("file_name", file.name)
        |> Map.put("file_type", file.mime)
        |> Map.put("resource_type", "file")

      save(row, attachment: attachment)
    else
      {:ok, %{status: 401}} -> {:error, :authorization}
      {:ok, %{status: 403}} -> {:error, :permission}
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :upload_failed}
    end
  end

  def sync(token, key, type, args) do
    command_id = uuid(key)
    temp_id = uuid(key <> ":temp")
    command = %{type: type, uuid: command_id, temp_id: temp_id, args: args}

    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           Todoist.request("api/v1/sync", token,
             method: :post,
             form: [commands: Jason.encode!([command])],
             retry: :transient,
             max_retries: 2,
             retry_log_level: false
           ),
         "ok" <- get_in(body, ["sync_status", command_id]),
         id when is_binary(id) <- get_in(body, ["temp_id_mapping", temp_id]) do
      {:ok, id}
    else
      {:ok, %{status: 401}} -> {:error, :authorization}
      {:ok, %{status: 403}} -> {:error, :permission}
      _ -> {:error, :todoist_failed}
    end
  end
end
