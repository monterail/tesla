defmodule Tesla.Builder do
  @http_verbs ~w(head get delete trace options post put patch)a
  @body ~w(post put patch)a

  require Logger

  defmacro __using__(opts \\ []) do
    unless Application.get_env(:tesla, :warning_acknowledged, false) do
      Logger.warn("""
      `use Tesla.Builder` and `use Tesla` are soft-deprecated. It will be removed in future major version in favor of
      Runtime Configuration instead.

      Read more and follow the issues:
      - https://github.com/elixir-tesla/tesla/issues/612
      - https://github.com/elixir-tesla/tesla/issues/377

      If you wish to turn off this warning, add the following to your config.exs:

      ```elixir
      config :tesla, warning_acknowledged: true
      ```
      """)
    end

    opts = Macro.prewalk(opts, &Macro.expand(&1, __CALLER__))
    docs = Keyword.get(opts, :docs, true)

    quote do
      Module.register_attribute(__MODULE__, :__middleware__, accumulate: true)
      Module.register_attribute(__MODULE__, :__adapter__, [])

      if unquote(docs) do
        @typedoc "Options that may be passed to a request function. See `request/2` for detailed descriptions."
      else
        @typedoc false
      end

      @type option ::
              {:method, Tesla.Env.method()}
              | {:url, Tesla.Env.url()}
              | {:query, Tesla.Env.query()}
              | {:headers, Tesla.Env.headers()}
              | {:body, Tesla.Env.body()}
              | {:opts, Tesla.Env.opts()}

      if unquote(docs) do
        @doc """
        Perform a request.

        ## Options

        - `:method` - the request method, one of [`:head`, `:get`, `:delete`, `:trace`, `:options`, `:post`, `:put`, `:patch`]
        - `:url` - either full url e.g. "http://example.com/some/path" or just "/some/path" if using `Tesla.Middleware.BaseUrl`
        - `:query` - a keyword list of query params, e.g. `[page: 1, per_page: 100]`
        - `:headers` - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
        - `:body` - depends on used middleware:
            - by default it can be a binary
            - if using e.g. JSON encoding middleware it can be a nested map
            - if adapter supports it it can be a Stream with any of the above
        - `:opts` - custom, per-request middleware or adapter options

        ## Examples

            ExampleApi.request(method: :get, url: "/users/path")

            # use shortcut methods
            ExampleApi.get("/users/1")
            ExampleApi.post(client, "/users", %{name: "Jon"})
        """
      else
        @doc false
      end

      @spec request(Tesla.Env.client(), [option]) :: Tesla.Env.result()
      def request(%Tesla.Client{} = client \\ %Tesla.Client{}, options) do
        Tesla.execute(__MODULE__, client, options)
      end

      if unquote(docs) do
        @doc """
        Perform request and raise in case of error.

        This is similar to `request/2` behaviour from Tesla 0.x

        See `request/2` for list of available options.
        """
      else
        @doc false
      end

      @spec request!(Tesla.Env.client(), [option]) :: Tesla.Env.t() | no_return
      def request!(%Tesla.Client{} = client \\ %Tesla.Client{}, options) do
        Tesla.execute!(__MODULE__, client, options)
      end

      unquote(generate_http_verbs(opts))

      import Tesla.Builder, only: [plug: 1, plug: 2, adapter: 1, adapter: 2]
      @before_compile Tesla.Builder
    end
  end

  @doc """
  Attach middleware to your API client.

  ```elixir
  defmodule ExampleApi do
    use Tesla

    # plug middleware module with options
    plug Tesla.Middleware.BaseUrl, "http://api.example.com"

    # or without options
    plug Tesla.Middleware.JSON

    # or a custom middleware
    plug MyProject.CustomMiddleware
  end
  """

  defmacro plug(middleware, opts) do
    quote do
      @__middleware__ {
        {unquote(Macro.escape(middleware)), unquote(Macro.escape(opts))},
        {:middleware, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro plug(middleware) do
    quote do
      @__middleware__ {
        unquote(Macro.escape(middleware)),
        {:middleware, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  @doc """
  Choose adapter for your API client.

  ```
  defmodule ExampleApi do
    use Tesla

    # set adapter as module
    adapter Tesla.Adapter.Hackney

    # set adapter as anonymous function
    adapter fn env ->
      ...
      env
    end
  end
  """
  defmacro adapter(name, opts) do
    quote do
      @__adapter__ {
        {unquote(Macro.escape(name)), unquote(Macro.escape(opts))},
        {:adapter, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro adapter(name) do
    quote do
      @__adapter__ {
        unquote(Macro.escape(name)),
        {:adapter, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro __before_compile__(env) do
    adapter =
      env.module
      |> Module.get_attribute(:__adapter__)
      |> compile()

    middleware =
      env.module
      |> Module.get_attribute(:__middleware__)
      |> Enum.reverse()
      |> compile()

    quote location: :keep do
      def __middleware__, do: unquote(middleware)
      def __adapter__, do: unquote(adapter)
    end
  end

  def client(pre, post, adapter \\ nil)

  def client(pre, post, nil) do
    %Tesla.Client{pre: runtime(pre), post: runtime(post)}
  end

  def client(pre, post, adapter) do
    %Tesla.Client{pre: runtime(pre), post: runtime(post), adapter: runtime(adapter)}
  end

  @default_opts []

  defp compile(nil), do: nil
  defp compile(list) when is_list(list), do: Enum.map(list, &compile/1)

  # {Tesla.Middleware.Something, opts}
  defp compile({{{:__aliases__, _, _} = ast_mod, ast_opts}, {_kind, _caller}}) do
    quote do: {unquote(ast_mod), :call, [unquote(ast_opts)]}
  end

  # Tesla.Middleware.Something
  defp compile({{:__aliases__, _, _} = ast_mod, {_kind, _caller}}) do
    quote do: {unquote(ast_mod), :call, [unquote(@default_opts)]}
  end

  # fn env -> ... end
  defp compile({{:fn, _, _} = ast_fun, {_kind, _caller}}) do
    quote do: {:fn, unquote(ast_fun)}
  end

  defp runtime(list) when is_list(list), do: Enum.map(list, &runtime/1)
  defp runtime({module, opts}) when is_atom(module), do: {module, :call, [opts]}
  defp runtime(fun) when is_function(fun), do: {:fn, fun}
  defp runtime(module) when is_atom(module), do: {module, :call, [@default_opts]}

  defp generate_http_verbs(opts) do
    only = Keyword.get(opts, :only, @http_verbs)
    except = Keyword.get(opts, :except, [])
    docs = Keyword.get(opts, :docs, true)

    for method <- @http_verbs do
      for bang <- [:safe, :bang],
          client <- [:client, :noclient],
          opts <- [:opts, :noopts],
          method in only && method not in except do
        gen(method, bang, client, opts, docs)
      end
    end
  end

  defp gen(method, safe, client, opts, docs) do
    quote location: :keep do
      unquote(gen_doc(method, safe, client, opts, docs))
      unquote(gen_spec(method, safe, client, opts))
      unquote(gen_fun(method, safe, client, opts))
    end
  end

  defp gen_doc(method, safe, :client, :opts, true) do
    request = to_string(req(safe))
    name = name(method, safe)

    {body, body_line} =
      if method in @body do
        {~s|, %{name: "Jon"}|, ""}
      else
        {"", ~s|#{name}(client, "/users", body: %{name: "Jon"})|}
      end

    quote location: :keep do
      @doc """
      Perform a #{unquote(method |> to_string |> String.upcase())} request.

      See `#{unquote(request)}/1` or `#{unquote(request)}/2` for options definition.

          #{unquote(name)}("/users"#{unquote(body)})
          #{unquote(name)}("/users"#{unquote(body)}, query: [scope: "admin"])
          #{unquote(name)}(client, "/users"#{unquote(body)})
          #{unquote(name)}(client, "/users"#{unquote(body)}, query: [scope: "admin"])
          #{unquote(body_line)}
      """
    end
  end

  defp gen_doc(_method, _bang, _client, _opts, _) do
    quote location: :keep do
      @doc false
    end
  end

  defp gen_spec(method, safe, client, opts) do
    quote location: :keep do
      @spec unquote(name(method, safe))(unquote_splicing(types(method, client, opts))) ::
              unquote(type(safe))
    end
  end

  defp gen_fun(method, safe, client, opts) do
    quote location: :keep do
      def unquote(name(method, safe))(unquote_splicing(inputs(method, client, opts))) do
        unquote(req(safe))(unquote_splicing(outputs(method, client, opts)))
      end
    end
    |> gen_guards(opts)
  end

  defp gen_guards({:def, _, [head, [do: body]]}, :opts) do
    quote do
      def unquote(head) when is_list(opts), do: unquote(body)
    end
  end

  defp gen_guards(def, _opts), do: def

  defp name(method, :safe), do: method
  defp name(method, :bang), do: String.to_atom("#{method}!")

  defp req(:safe), do: :request
  defp req(:bang), do: :request!

  defp types(method, client, opts), do: type(client) ++ type(:url) ++ type(method) ++ type(opts)

  defp type(:safe), do: quote(do: Tesla.Env.result())
  defp type(:bang), do: quote(do: Tesla.Env.t() | no_return)

  defp type(:client), do: [quote(do: Tesla.Env.client())]
  defp type(:noclient), do: []
  defp type(:opts), do: [quote(do: [option])]
  defp type(:noopts), do: []
  defp type(:url), do: [quote(do: Tesla.Env.url())]
  defp type(method) when method in @body, do: [quote(do: Tesla.Env.body())]
  defp type(_method), do: []

  defp inputs(method, client, opts),
    do: input(client) ++ input(:url) ++ input(method) ++ input(opts)

  defp input(:client), do: [quote(do: %Tesla.Client{} = client)]
  defp input(:noclient), do: []
  defp input(:opts), do: [quote(do: opts)]
  defp input(:noopts), do: []
  defp input(:url), do: [quote(do: url)]
  defp input(method) when method in @body, do: [quote(do: body)]
  defp input(_method), do: []

  defp outputs(method, client, opts), do: output(client) ++ [output(output(method), opts)]
  defp output(:client), do: [quote(do: client)]
  defp output(:noclient), do: []
  defp output(m) when m in @body, do: quote(do: [method: unquote(m), url: url, body: body])
  defp output(m), do: quote(do: [method: unquote(m), url: url])
  defp output(prev, :opts), do: quote(do: unquote(prev) ++ opts)
  defp output(prev, :noopts), do: prev
end
