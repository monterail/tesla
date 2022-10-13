if Code.ensure_loaded?(:hackney) do
  defmodule Tesla.Adapter.Hackney do
    @moduledoc """
    Adapter for [hackney](https://github.com/benoitc/hackney).

    Remember to add `{:hackney, "~> 1.13"}` to dependencies (and `:hackney` to applications in `mix.exs`)
    Also, you need to recompile tesla after adding `:hackney` dependency:

    ```
    mix deps.clean tesla
    mix deps.compile tesla
    ```

    ## Examples

    ```
    # set globally in config/config.exs
    config :tesla, :adapter, Tesla.Adapter.Hackney

    # set per module
    defmodule MyClient do
      use Tesla

      adapter Tesla.Adapter.Hackney
    end
    ```
    """
    @behaviour Tesla.Adapter
    alias Tesla.Multipart

    @impl Tesla.Adapter
    def call(env, opts) do
      with {:ok, status, headers, body} <- request(env, opts) do
        {:ok, %{env | status: status, headers: format_headers(headers), body: format_body(body)}}
      end
    end

    defp format_headers(headers) do
      for {key, value} <- headers do
        {String.downcase(to_string(key)), to_string(value)}
      end
    end

    defp format_body(data) when is_list(data), do: IO.iodata_to_binary(data)

    defp format_body(data)
         when is_binary(data) or is_reference(data) or is_function(data),
         do: data

    defp request(env, opts) do
      request(
        env.method,
        Tesla.build_url(env.url, env.query),
        env.headers,
        env.body,
        env.response,
        Tesla.Adapter.opts(env, opts)
        |> Keyword.put_new(:stream_owner, env.__pid__)
      )
    end

    defp request(method, url, headers, %Stream{} = body, response, opts),
      do: request_stream(method, url, headers, body, response, opts)

    defp request(method, url, headers, body, response, opts) when is_function(body),
      do: request_stream(method, url, headers, body, response, opts)

    defp request(method, url, headers, %Multipart{} = mp, response, opts) do
      headers = headers ++ Multipart.headers(mp)
      body = Multipart.body(mp)

      request(method, url, headers, body, response, opts)
    end

    defp request(method, url, headers, body, type, opts) do
      response = :hackney.request(method, url, headers, body || '', opts)
      handle(response, type, Keyword.get(opts, :stream_owner))
    end

    defp request_stream(method, url, headers, body, type, opts) do
      handle_wrap = fn result ->
        handle(result, type, Keyword.get(opts, :stream_owner))
      end

      with {:ok, ref} <- :hackney.request(method, url, headers, :stream, opts) do
        case send_stream(ref, body) do
          :ok -> handle_wrap.(:hackney.start_response(ref))
          error -> handle_wrap.(error)
        end
      else
        e -> handle_wrap.(e)
      end
    end

    defp send_stream(ref, body) do
      Enum.reduce_while(body, :ok, fn data, _ ->
        case :hackney.send_body(ref, data) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp handle({:error, _} = error, _, _), do: error
    defp handle({:ok, status, headers}, _, _), do: {:ok, status, headers, []}

    defp handle({:ok, ref}, :default, _) when is_reference(ref) do
      handle_async_response({ref, %{status: nil, headers: nil}})
    end

    defp handle({:ok, ref}, :stream, pid) when is_reference(ref) do
      handle_async_response({ref, %{status: nil, headers: nil}})
      |> handle(:stream, pid)
    end

    defp handle({:ok, status, headers, ref}, :default, _) when is_reference(ref) do
      with {:ok, body} <- :hackney.body(ref) do
        {:ok, status, headers, body}
      end
    end

    defp handle({:ok, status, headers, ref}, :stream, pid) when is_reference(ref) do
      :hackney.controlling_process(ref, pid)

      body =
        Stream.resource(
          fn -> nil end,
          fn _ ->
            case :hackney.stream_body(ref) do
              :done ->
                {:halt, nil}

              {:ok, data} ->
                {[data], nil}

              {:error, reason} ->
                raise inspect(reason)
            end
          end,
          fn _ -> :hackney.close(ref) end
        )

      {:ok, status, headers, body}
    end

    defp handle({:ok, status, headers, body}, _, _), do: {:ok, status, headers, body}

    defp handle_async_response({ref, %{headers: headers, status: status}})
         when not (is_nil(headers) or is_nil(status)) do
      {:ok, status, headers, ref}
    end

    defp handle_async_response({ref, output}) do
      receive do
        {:hackney_response, ^ref, {:status, status, _}} ->
          handle_async_response({ref, %{output | status: status}})

        {:hackney_response, ^ref, {:headers, headers}} ->
          handle_async_response({ref, %{output | headers: headers}})
      end
    end
  end
end
