defmodule Tesla.Client do
  @type adapter :: module | {module, any} | (Tesla.Env.t() -> Tesla.Env.result())
  @type middleware :: module | {module, any}

  @type t :: %__MODULE__{
          pre: Tesla.Env.stack(),
          post: Tesla.Env.stack(),
          adapter: Tesla.Env.runtime() | nil
        }
  defstruct fun: nil,
            pre: [],
            post: [],
            adapter: nil

  @doc ~S"""
  Returns the client's adapter in the same form it was provided.
  This can be used to copy an adapter from one client to another.

  ## Examples

      iex> client = Tesla.client([], {Tesla.Adapter.Hackney, [recv_timeout: 30_000]})
      iex> Tesla.Client.adapter(client)
      {Tesla.Adapter.Hackney, [recv_timeout: 30_000]}
  """
  @spec adapter(t) :: adapter
  def adapter(client) do
    if client.adapter, do: unruntime(client.adapter)
  end

  @doc ~S"""
  Returns the client's middleware in the same form it was provided.
  This can be used to copy middleware from one client to another.

  ## Examples

      iex> middleware = [Tesla.Middleware.JSON, {Tesla.Middleware.BaseUrl, "https://api.github.com"}]
      iex> client = Tesla.client(middleware)
      iex> Tesla.Client.middleware(client)
      [Tesla.Middleware.JSON, {Tesla.Middleware.BaseUrl, "https://api.github.com"}]
  """
  @spec middleware(t) :: [middleware]
  def middleware(client) do
    unruntime(client.pre)
  end

  @doc ~S"""
  Given an update function, create a new client by transforming the
  list of middlewares for an existing one.

  ## Examples

      iex> middleware = [{Tesla.Middleware.BaseUrl, "https://api.github.com"}]
      iex> client = Tesla.client(middleware)
      iex> new_client = Tesla.Client.update_middleware(client, &([Tesla.Middleware.JSON] ++ &1))
      iex> Tesla.Client.middleware(new_client)
      [Tesla.Middleware.JSON, {Tesla.Middleware.BaseUrl, "https://api.github.com"}]
  """
  @spec update_middleware(t(), ([middleware()] -> [middleware()])) :: t()
  def update_middleware(client, update_fun) do
    existing_middleware = middleware(client)
    new_middleware = update_fun.(existing_middleware)
    Tesla.client(new_middleware, adapter(client))
  end

  defp unruntime(list) when is_list(list), do: Enum.map(list, &unruntime/1)
  defp unruntime({module, :call, [[]]}) when is_atom(module), do: module
  defp unruntime({module, :call, [opts]}) when is_atom(module), do: {module, opts}
  defp unruntime({:fn, fun}) when is_function(fun), do: fun
end
