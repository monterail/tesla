if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Tesla.Adapter.Mint do
    @moduledoc """
    Adapter for [mint](https://github.com/elixir-mint/mint).

    **NOTE:** The minimum supported Elixir version for mint is 1.5.0

    Remember to add `{:mint, "~> 1.0"}` and `{:castore, "~> 0.1"}` to dependencies.
    Also, you need to recompile tesla after adding `:mint` dependency:

    ```shell
    mix deps.clean tesla
    mix deps.compile tesla
    ```

    ## Examples

    ```elixir
    # set globally in config/config.exs
    config :tesla, :adapter, Tesla.Adapter.Mint
    # set per module
    defmodule MyClient do
      def client do
        Tesla.client([], Tesla.Adapter.Mint)
      end
    end

    # set global custom cacertfile
    config :tesla, adapter: {Tesla.Adapter.Mint, cacert: ["path_to_cacert"]}
    ```

    ## Adapter specific options:

    - `:timeout` - Time in milliseconds, while process, will wait for mint messages. Defaults to `2_000`.
    - `:body_as` - What will be returned in `%Tesla.Env{}` body key. Possible values - `:plain`, `:stream`, `:chunks`. Defaults to `:plain`.
      - `:plain` - as binary.
      - `:stream` - as stream. If you don't want to close connection (because you want to reuse it later) pass `close_conn: false` in adapter opts.
      - `:chunks` - as chunks. You can get response body in chunks using `Tesla.Adapter.Mint.read_chunk/3` function.
      Processing of the chunks and checking body size must be done by yourself. Example of processing function is in `test/tesla/adapter/mint_test.exs` - `Tesla.Adapter.MintTest.read_body/4`. If you don't need connection later don't forget to close it with `Tesla.Adapter.Mint.close/1`.
    - `:max_body` - Max response body size in bytes. Works only with `body_as: :plain`, with other settings you need to check response body size by yourself.
    - `:conn` - Opened connection with mint. Is used for reusing mint connections.
    - `:original` - Original host with port, for which reused connection was open. Needed for `Tesla.Middleware.FollowRedirects`. Otherwise adapter will use connection for another open host.
    - `:close_conn` - Close connection or not after receiving full response body. Is used for reusing mint connections. Defaults to `true`.
    - `:proxy` - Proxy settings. E.g.: `{:http, "localhost", 8888, []}`, `{:http, "127.0.0.1", 8888, []}`
    - `:transport_opts` - Keyword list of HTTP or HTTPS options passed into `:gen_tcp` or `:ssl` respectively by mint. See [mint's docs on `transport_opts`](https://hexdocs.pm/mint/Mint.HTTP.html#connect/4-transport-options).
    """

    @behaviour Tesla.Adapter

    import Tesla.Adapter.Shared
    alias Tesla.Multipart
    alias Mint.HTTP

    @default timeout: 2_000, body_as: :plain, close_conn: true, mode: :active

    @tags [:tcp_error, :ssl_error, :tcp_closed, :ssl_closed, :tcp, :ssl]

    @impl Tesla.Adapter
    def call(env, opts) do
      opts = Tesla.Adapter.opts(@default, env, opts)

      with {:ok, status, headers, body} <- request(env, opts) do
        {:ok, %{env | status: status, headers: headers, body: body}}
      end
    end

    @doc """
    Reads chunk of the response body.
    Returns `{:fin, HTTP.t(), binary()}` if all body received, otherwise returns `{:nofin, HTTP.t(), binary()}`.
    """

    @spec read_chunk(HTTP.t(), reference(), keyword()) ::
            {:fin, HTTP.t(), binary()} | {:nofin, HTTP.t(), binary()}
    def read_chunk(conn, ref, opts) do
      with {:ok, conn, acc} <- receive_packet(conn, ref, Enum.into(opts, %{})),
           {state, data} <- response_state(acc) do
        {:ok, conn} =
          if state == :fin and opts[:close_conn] do
            close(conn)
          else
            {:ok, conn}
          end

        {state, conn, data}
      end
    end

    @doc """
    Closes mint connection.
    """
    @spec close(HTTP.t()) :: {:ok, HTTP.t()}
    defdelegate close(conn), to: HTTP

    defp request(env, opts) do
      request(
        format_method(env.method),
        Tesla.build_url(env),
        env.headers,
        env.body,
        Enum.into(opts, %{})
      )
    end

    defp request(method, url, headers, %Stream{} = body, opts) do
      fun = stream_to_fun(body)
      request(method, url, headers, fun, opts)
    end

    defp request(method, url, headers, %Multipart{} = body, opts) do
      headers = headers ++ Multipart.headers(body)
      fun = stream_to_fun(Multipart.body(body))
      request(method, url, headers, fun, opts)
    end

    defp request(method, url, headers, body, opts),
      do: do_request(method, url, headers, body, opts)

    defp do_request(method, url, headers, body, opts) do
      with uri <- URI.parse(url),
           path <- prepare_path(uri.path, uri.query),
           opts <- check_original(uri, opts),
           {:ok, conn, opts} <- open_conn(uri, opts),
           {:ok, conn, ref} <- make_request(conn, method, path, headers, body) do
        format_response(conn, ref, opts)
      end
    end

    defp check_original(uri, %{original: original} = opts) do
      Map.put(opts, :original_matches, original == "#{uri.host}:#{uri.port}")
    end

    defp check_original(_uri, opts), do: opts

    defp open_conn(_uri, %{conn: conn, original_matches: true} = opts) do
      {:ok, conn, opts}
    end

    defp open_conn(uri, %{conn: conn, original_matches: false} = opts) do
      opts =
        opts
        |> Map.put_new(:old_conn, conn)
        |> Map.delete(:conn)

      open_conn(uri, opts)
    end

    defp open_conn(uri, opts) do
      opts =
        with "https" <- uri.scheme,
             global_cacertfile when not is_nil(global_cacertfile) <-
               Application.get_env(:tesla, Tesla.Adapter.Mint)[:cacert] do
          Map.update(opts, :transport_opts, [cacertfile: global_cacertfile], fn tr_opts ->
            Keyword.put_new(tr_opts, :cacertfile, global_cacertfile)
          end)
        else
          _ -> opts
        end

      opts = Map.put_new(opts, :mode, :passive)

      with {:ok, conn} <-
             HTTP.connect(String.to_atom(uri.scheme), uri.host, uri.port, Enum.into(opts, [])) do
        # If there were redirects, and passed `closed_conn: false`, we need to close opened connections to these intermediate hosts.
        {:ok, conn, Map.put(opts, :close_conn, true)}
      end
    end

    defp make_request(conn, method, path, headers, body) when is_function(body) do
      with {:ok, conn, ref} <-
             HTTP.request(
               conn,
               method,
               path,
               headers,
               :stream
             ),
           {:ok, conn} <- stream_request(conn, ref, body) do
        {:ok, conn, ref}
      end
    end

    defp make_request(conn, method, path, headers, body) do
      case HTTP.request(conn, method, path, headers, body) do
        {:ok, conn, ref} ->
          {:ok, conn, ref}

        {:error, _conn, error} ->
          {:error, error}
      end
    end

    defp stream_request(conn, ref, fun) do
      case next_chunk(fun) do
        {:ok, item, fun} when is_list(item) ->
          chunk = List.to_string(item)
          {:ok, conn} = HTTP.stream_request_body(conn, ref, chunk)
          stream_request(conn, ref, fun)

        {:ok, item, fun} ->
          {:ok, conn} = HTTP.stream_request_body(conn, ref, item)
          stream_request(conn, ref, fun)

        :eof ->
          HTTP.stream_request_body(conn, ref, :eof)
      end
    end

    defp format_response(conn, ref, %{body_as: :plain} = opts) do
      with {:ok, response} <- receive_responses(conn, ref, opts) do
        {:ok, response[:status], response[:headers], response[:data]}
      end
    end

    defp format_response(conn, ref, %{body_as: :chunks} = opts) do
      with {:ok, conn, %{status: status, headers: headers} = acc} <-
             receive_headers_and_status(conn, ref, opts),
           {state, data} <-
             response_state(acc) do
        {:ok, conn} =
          if state == :fin and opts[:close_conn] do
            close(conn)
          else
            {:ok, conn}
          end

        {:ok, status, headers, %{conn: conn, ref: ref, opts: opts, body: {state, data}}}
      end
    end

    defp format_response(conn, ref, %{body_as: :stream} = opts) do
      # there can be some data already
      with {:ok, conn, %{status: status, headers: headers} = acc} <-
             receive_headers_and_status(conn, ref, opts) do
        body_as_stream =
          Stream.resource(
            fn -> %{conn: conn, data: acc[:data], done: acc[:done]} end,
            fn
              %{conn: conn, data: data, done: true} ->
                {[data], %{conn: conn, is_fin: true}}

              %{conn: conn, data: data} when is_binary(data) ->
                {[data], %{conn: conn}}

              %{conn: conn, is_fin: true} ->
                {:halt, %{conn: conn}}

              %{conn: conn} ->
                case receive_packet(conn, ref, opts) do
                  {:ok, conn, %{done: true, data: data}} ->
                    {[data], %{conn: conn, is_fin: true}}

                  {:ok, conn, %{done: true}} ->
                    {[], %{conn: conn, is_fin: true}}

                  {:ok, conn, %{data: data}} ->
                    {[data], %{conn: conn}}

                  {:ok, conn, _} ->
                    {[], %{conn: conn}}
                end
            end,
            fn %{conn: conn} -> if opts[:close_conn], do: {:ok, _conn} = close(conn) end
          )

        {:ok, status, headers, body_as_stream}
      end
    end

    defp receive_responses(conn, ref, opts, acc \\ %{}) do
      with {:ok, conn, acc} <- receive_packet(conn, ref, opts, acc),
           :ok <- check_data_size(acc, conn, opts) do
        if acc[:done] do
          if opts[:close_conn], do: {:ok, _conn} = close(conn)
          {:ok, acc}
        else
          receive_responses(conn, ref, opts, acc)
        end
      end
    end

    defp check_data_size(%{data: data}, conn, %{max_body: max_body} = opts)
         when is_binary(data) do
      if max_body - byte_size(data) >= 0 do
        :ok
      else
        if opts[:close_conn], do: {:ok, _conn} = close(conn)
        {:error, :body_too_large}
      end
    end

    defp check_data_size(_, _, _), do: :ok

    defp receive_headers_and_status(conn, ref, opts, acc \\ %{}) do
      with {:ok, conn, acc} <- receive_packet(conn, ref, opts, acc) do
        case acc do
          %{status: _status, headers: _headers} -> {:ok, conn, acc}
          # if we don't have status or headers we try to get them in next packet
          _ -> receive_headers_and_status(conn, ref, opts, acc)
        end
      end
    end

    defp response_state(%{done: true, data: data}), do: {:fin, data}
    defp response_state(%{data: data}), do: {:nofin, data}
    defp response_state(%{done: true}), do: {:fin, ""}
    defp response_state(_), do: {:nofin, ""}

    defp receive_packet(conn, ref, opts, acc \\ %{}) do
      with {:ok, conn, responses} <- receive_message(conn, opts),
           acc <- reduce_responses(responses, ref, acc) do
        {:ok, conn, acc}
      else
        {:error, error} ->
          if opts[:close_conn], do: {:ok, _conn} = close(conn)
          {:error, error}

        {:error, _conn, error, _res} ->
          if opts[:close_conn], do: {:ok, _conn} = close(conn)
          # TODO: (breaking change) fix typo in error message, "Encounter" => "Encountered"
          {:error, "Encounter Mint error #{inspect(error)}"}

        :unknown ->
          if opts[:close_conn], do: {:ok, _conn} = close(conn)
          {:error, :unknown}
      end
    end

    defp receive_message(conn, %{mode: :active} = opts) do
      receive do
        message when is_tuple(message) and elem(message, 0) in @tags ->
          HTTP.stream(conn, message)
      after
        opts[:timeout] -> {:error, :timeout}
      end
    end

    defp receive_message(conn, %{mode: :passive} = opts),
      do: HTTP.recv(conn, 0, opts[:timeout])

    defp reduce_responses(responses, ref, acc) do
      Enum.reduce(responses, acc, fn
        {:error, ^ref, _error}, acc ->
          acc

        {:push_promise, ^ref, _promised_request_ref, _headers}, acc ->
          acc

        {:status, ^ref, code}, acc ->
          Map.put(acc, :status, code)

        {:status, _promised_request_ref, _code}, acc ->
          acc

        {:headers, ^ref, headers}, acc ->
          Map.update(acc, :headers, headers, &(&1 ++ headers))

        {:headers, _promised_request_ref, _headers}, acc ->
          acc

        {:data, ^ref, data}, acc ->
          Map.update(acc, :data, data, &(&1 <> data))

        {:data, _promised_request_ref, _data}, acc ->
          acc

        {:done, ^ref}, acc ->
          Map.put(acc, :done, true)

        {:done, _promised_request_ref}, acc ->
          acc
      end)
    end
  end
end
