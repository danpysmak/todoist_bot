defmodule TodoistBot.Attachment do
  @moduledoc "Extract original Telegram media; never return token-bearing download links."
  @types ["document", "audio", "voice", "video", "video_note", "animation", "sticker"]

  def extract(%{"photo" => photos}) when is_list(photos) and photos != [] do
    photo = Enum.max_by(photos, &((&1["width"] || 0) * (&1["height"] || 0)))
    {:ok, normalize(photo, "photo", "photo.jpg", "image/jpeg")}
  end

  def extract(message) when is_map(message) do
    # Animation messages may also contain a document: prefer the animation descriptor.
    type = Enum.find(["animation" | @types -- ["animation"]], &is_map(message[&1]))

    if type do
      {name, mime} = defaults(type, message[type])
      {:ok, normalize(message[type], type, name, mime)}
    else
      :none
    end
  end

  def extract(_), do: :none

  defp defaults("voice", _), do: {"voice.ogg", "audio/ogg"}
  defp defaults("video_note", _), do: {"video-note.mp4", "video/mp4"}
  defp defaults("video", _), do: {"video.mp4", "video/mp4"}
  defp defaults("animation", _), do: {"animation.mp4", "video/mp4"}
  defp defaults("audio", _), do: {"audio.mp3", "audio/mpeg"}

  defp defaults("sticker", %{"is_animated" => true}),
    do: {"sticker.tgs", "application/x-tgsticker"}

  defp defaults("sticker", %{"is_video" => true}), do: {"sticker.webm", "video/webm"}
  defp defaults("sticker", _), do: {"sticker.webp", "image/webp"}
  defp defaults(_, _), do: {"document.bin", "application/octet-stream"}

  defp normalize(file, kind, name, mime) do
    %{
      id: file["file_id"],
      size: file["file_size"],
      kind: kind,
      name: safe_name(file["file_name"] || name),
      mime: safe_mime(file["mime_type"] || mime)
    }
  end

  def safe_name(name) do
    name
    |> String.replace(~r/[\\\/\x00-\x1f\x7f";]/u, "_")
    |> String.replace(~r/[\x{202a}-\x{202e}\x{2066}-\x{2069}]/u, "")
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      n when n in ["", ".", ".."] -> "attachment.bin"
      n -> n
    end
  end

  def safe_mime(mime) do
    if Regex.match?(~r/\A[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+\z/, mime),
      do: mime,
      else: "application/octet-stream"
  end

  def limit,
    do: min(Application.get_env(:todoist_bot, :max_attachment_bytes, 5_000_000), 20_000_000)

  def size_ok(nil), do: :ok

  def size_ok(size) when is_integer(size) and size >= 0 do
    if size <= limit(), do: :ok, else: {:error, :too_large}
  end

  def size_ok(_), do: {:error, :invalid_file}
end
