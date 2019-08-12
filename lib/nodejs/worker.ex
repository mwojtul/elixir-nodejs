defmodule NodeJS.Worker do
  use GenServer

  # Port can't do more than this.
  @read_chunk_size 65_536

  @moduledoc """
  A genserver that controls the starting of the node service
  """

  @doc """
  Starts the Supervisor and underlying node service.
  """
  @spec start_link([binary()]) :: {:ok, pid} | {:error, any()}
  def start_link([module_path]) do
    GenServer.start_link(__MODULE__, module_path)
  end

  defp node_service_path() do
    Path.join(:code.priv_dir(:nodejs), "server.js")
  end

  # --- GenServer Callbacks ---
  @doc false
  def init(module_path) do
    node = System.find_executable("node")

    port =
      Port.open(
        {:spawn_executable, node},
        line: @read_chunk_size,
        env: [
          {'NODE_PATH', String.to_charlist(module_path)},
          {'WRITE_CHUNK_SIZE', String.to_charlist("#{@read_chunk_size}")}
        ],
        args: [node_service_path()]
      )

    {:ok, [node_service_path(), port, %{}]}
  end

  defp get_response({_, {:data, {flag, chunk}}}, data \\ '') do
    data = data ++ chunk

    case flag do
      :eol -> data
      :noeol -> receive do: (result -> get_response(result, data))
    end
  end

  @doc false
  def handle_call({module, args, caller_pid}, from, [path, port, caller_pid_map] = state) when is_tuple(module) do
    GenServer.reply(from, nil)
    uuid = System.unique_integer([:positive])
    caller_pid_map = Map.put(caller_pid_map, uuid, caller_pid)
    body = Jason.encode!([Tuple.to_list(module), args, uuid])
    Port.command(port, "#{body}\n")
    {:noreply, [path, port, caller_pid_map]}
  end

  def handle_info(msg, [path, port, caller_pid_map] = state) do
    {uuid, result} =
      msg
      |> get_response('')
      |> decode()

    {caller_pid, caller_pid_map} = Map.pop(caller_pid_map, uuid)
    send(caller_pid, result)
    {:noreply, [path, port, caller_pid_map]}
  end

  defp decode(data) do
    data
    |> to_string()
    |> Jason.decode!()
    |> case do
      [true, uuid, success] -> {uuid, {:ok, success}}
      [false, uuid, error] -> {uuid, {:error, error}}
    end
  end

  @doc false
  def terminate(_reason, [_, port, _]) do
    send(port, {self(), :close})
  end
end
