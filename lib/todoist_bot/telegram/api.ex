defmodule TodoistBot.Telegram.API do
  @adapter Application.compile_env!(:todoist_bot, :telegram_adapter)

  @callback request(request :: Req.Request.t()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}

  def new(method) do
    token = Application.fetch_env!(:todoist_bot, :bot_token)

    Req.new(
      base_url: "https://api.telegram.org",
      url: "bot{token}/#{method}",
      path_params: [token: token],
      path_params_style: :curly,
      method: :post,
      redirect: false,
      retry: false,
      retry_log_level: false,
      receive_timeout: 30_000
    )
  end

  def download(file_id) when is_binary(file_id) do
    with {:ok, %{status: 200, body: %{"ok" => true, "result" => file}}} <-
           request("getFile", %{file_id: file_id}),
         :ok <- TodoistBot.Attachment.size_ok(file["file_size"]),
         path when is_binary(path) <- file["file_path"],
         true <- valid_path?(path) do
      token = Application.fetch_env!(:todoist_bot, :bot_token)

      request =
        Req.new(
          url: "https://api.telegram.org/file/bot#{token}/#{path}",
          method: :get,
          redirect: false,
          retry: :transient,
          max_retries: 2,
          retry_log_level: false,
          decode_body: false,
          raw: true,
          receive_timeout: 30_000,
          into: &collect/2
        )

      case @adapter.request(request) do
        {:ok, %{status: 200, body: bytes, private: private}} when is_binary(bytes) ->
          if private[:too_large], do: {:error, :too_large}, else: checked_bytes(bytes)

        _ ->
          {:error, :download_failed}
      end
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :download_failed}
    end
  end

  def download(_), do: {:error, :invalid_file}

  def valid_path?(path) do
    Regex.match?(~r/\A[a-zA-Z0-9_\/-]+\.[a-zA-Z0-9]+\z/, path) and
      not String.starts_with?(path, "/") and not String.contains?(path, "..")
  end

  def collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) > TodoistBot.Attachment.limit() do
      response = %{response | body: "", private: Map.put(response.private, :too_large, true)}
      {:halt, {request, response}}
    else
      {:cont, {request, %{response | body: body <> data}}}
    end
  end

  defp checked_bytes(bytes) do
    case TodoistBot.Attachment.size_ok(byte_size(bytes)) do
      :ok -> {:ok, bytes}
      error -> error
    end
  end

  def request(endpoint, body) do
    endpoint
    |> new()
    |> Req.merge(json: body)
    |> @adapter.request()
  end
end
