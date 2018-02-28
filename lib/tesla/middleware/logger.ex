defmodule Tesla.Middleware.Logger do
  @behaviour Tesla.Middleware

  @moduledoc """
  Log requests as single line.

  Logs request method, url, response status and time taken in milliseconds.

  ### Example usage
  ```
  defmodule MyClient do
    use Tesla

    plug Tesla.Middleware.Logger
  end
  ```

  ### Customize logging levels
  ```
  defmodule MyClient do
    use Tesla

    plug Tesla.Middleware.Logger, %{404 => :info}
  end
  ```

  ### Logger output
  ```
  2017-09-30 13:39:06.663 [info] GET http://example.com -> 200 (736.988 ms)
  ```

  See `Tesla.Middleware.DebugLogger` to log request/response body
  """

  require Logger

  @default_log_levels %{200 => :info, 300 => :warn, 400 => :error, 500 => :error}

  def call(env, next, opts) do
    {time, result} = :timer.tc(Tesla, :run, [env, next])
    log_levels = Keyword.get(opts || [], :log_levels, @default_log_levels)
    _ = log(env, result, time, log_levels)
    result
  end

  defp log(env, {:error, reason}, _time, _) do
    Logger.error("#{normalize_method(env)} #{env.url} -> #{inspect(reason)}")
  end

  defp log(_env, {:ok, env}, time, log_levels) do
    ms = :io_lib.format("~.3f", [time / 1000])
    message = "#{normalize_method(env)} #{env.url} -> #{env.status} (#{ms} ms)"
    log_level = log_level(env.status, log_levels)

    case log_level do
      :warn -> Logger.warn(message)
      :error -> Logger.error(message)
      _ -> Logger.info(message)
    end
  end

  defp log_level(status, log_levels) when is_map(log_levels) do
    case log_levels[status] do
      nil -> log_level(status, Map.to_list(log_levels))
      log_level -> log_level
    end
  end

  defp log_level(_, [{_, l}]), do: l
  defp log_level(status, [{s1, l1} | [{s2, _} | _]]) when status in s1..(s2 - 1), do: l1
  defp log_level(status, [_ | t]), do: log_level(status, t)

  defp normalize_method(env) do
    env.method |> to_string() |> String.upcase()
  end
end

defmodule Tesla.Middleware.DebugLogger do
  @behaviour Tesla.Middleware

  @moduledoc """
  Log full reqeust/response content


  ### Example usage
  ```
  defmodule MyClient do
    use Tesla

    plug Tesla.Middleware.DebugLogger
  end
  ```

  ### Logger output
  ```
  2017-09-30 13:41:56.281 [debug] > POST https://httpbin.org/post
  2017-09-30 13:41:56.281 [debug]
  2017-09-30 13:41:56.281 [debug] > a=3
  2017-09-30 13:41:56.432 [debug]
  2017-09-30 13:41:56.432 [debug] < HTTP/1.1 200
  2017-09-30 13:41:56.432 [debug] < access-control-allow-credentials: true
  2017-09-30 13:41:56.432 [debug] < access-control-allow-origin: *
  2017-09-30 13:41:56.432 [debug] < connection: keep-alive
  2017-09-30 13:41:56.432 [debug] < content-length: 280
  2017-09-30 13:41:56.432 [debug] < content-type: application/json
  2017-09-30 13:41:56.432 [debug] < date: Sat, 30 Sep 2017 11:41:55 GMT
  2017-09-30 13:41:56.432 [debug] < server: meinheld/0.6.1
  2017-09-30 13:41:56.432 [debug] < via: 1.1 vegur
  2017-09-30 13:41:56.432 [debug] < x-powered-by: Flask
  2017-09-30 13:41:56.432 [debug] < x-processed-time: 0.0011260509491
  2017-09-30 13:41:56.432 [debug]
  2017-09-30 13:41:56.432 [debug] > {
    "args": {},
    "data": "a=3",
    "files": {},
    "form": {},
    "headers": {
      "Connection": "close",
      "Content-Length": "3",
      "Content-Type": "",
      "Host": "httpbin.org"
    },
    "json": null,
    "origin": "0.0.0.0",
    "url": "https://httpbin.org/post"
  }
  ```
  """

  require Logger

  def call(env, next, _opts) do
    env
    |> log_request
    |> log_headers("> ")
    |> log_params("> ")
    |> log_body("> ")
    |> Tesla.run(next)
    |> case do
      {:ok, env} ->
        env
        |> log_response
        |> log_headers("< ")
        |> log_body("< ")

        {:ok, env}

      {:error, reason} ->
        log_exception(reason, "< ")
        {:error, reason}
    end
  end

  defp log_request(env) do
    _ = Logger.debug("> #{env.method |> to_string |> String.upcase()} #{env.url}")
    env
  end

  defp log_response(env) do
    _ = Logger.debug("")
    _ = Logger.debug("< HTTP/1.1 #{env.status}")
    env
  end

  defp log_headers(env, prefix) do
    for {k, v} <- env.headers do
      _ = Logger.debug("#{prefix}#{k}: #{v}")
    end

    env
  end

  defp log_params(env, prefix) do
    for {k, v} <- env.query do
      _ = Logger.debug("#{prefix} Query Param '#{k}': '#{v}'")
    end

    env
  end

  defp log_body(%Tesla.Env{} = env, _prefix) do
    Map.update!(env, :body, &log_body(&1, "> "))
  end

  defp log_body(nil, _), do: nil
  defp log_body([], _), do: nil
  defp log_body(%Stream{} = stream, prefix), do: log_body_stream(stream, prefix)
  defp log_body(stream, prefix) when is_function(stream), do: log_body_stream(stream, prefix)
  defp log_body(%Tesla.Multipart{} = mp, prefix), do: log_multipart_body(mp, prefix)

  defp log_body(data, prefix) when is_binary(data) or is_list(data) do
    _ = Logger.debug("")
    _ = Logger.debug(prefix <> to_string(data))
    data
  end

  defp log_body_stream(stream, prefix) do
    _ = Logger.debug("")
    Stream.each(stream, fn line -> Logger.debug(prefix <> line) end)
  end

  defp log_multipart_body(%Tesla.Multipart{} = mp, prefix) do
    _ = Logger.debug("")
    _ = Logger.debug(prefix <> "boundary: " <> mp.boundary)
    _ = Logger.debug(prefix <> "content_type_params: " <> inspect(mp.content_type_params))
    Enum.each(mp.parts, &Logger.debug(prefix <> inspect(&1)))

    mp
  end

  defp log_exception(reason, prefix) do
    _ = Logger.debug(prefix <> " (#{inspect(reason)})")
  end
end
