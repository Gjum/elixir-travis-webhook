defmodule TravisWebhook do
  require Logger

  def start(_type, _args) do
    conf = %{
      flood_bytes: 5000,
    } |> Map.merge(Map.new(Application.get_all_env(:travis_webhook)))

    upgrade_pid = spawn fn -> upgrade_loop(conf) end

    accept_pid = spawn fn ->
      {:ok, listen} = :gen_tcp.listen(conf.port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
      ])
      Logger.info "Listening for HTTP requests on port #{conf.port}"
      {:ok, socket} = :gen_tcp.accept(listen)
      accept_loop(listen, socket, conf, upgrade_pid)
    end

    {:ok, upgrade_pid, accept_pid}
  end

  def accept_loop(listen, socket, conf, upgrade_pid) do
    Logger.debug "New connection #{inspect socket}"
    pid = spawn fn -> handle_connection(conf, socket, upgrade_pid) end
    :ok = :gen_tcp.controlling_process(socket, pid)

    {:ok, socket} = :gen_tcp.accept(listen)
    __MODULE__.accept_loop(listen, socket, conf, upgrade_pid)
  end

  def handle_connection(conf, socket, upgrade_pid) do
    {:ok, header, body_start} = receive_header(socket, conf)
    %{token: token, branch: branch, repo_slug: repo_slug} = conf
    %{
      "authorization" => ^token,
      "travis-repo-slug" => ^repo_slug,
    } = header
    content_length = String.to_integer(header["content-length"])
    json = receive_payload(socket, body_start, content_length - byte_size(body_start))
    case json do
      %{"branch" => ^branch, "result" => 0} ->
        send(upgrade_pid, {:do_upgrade, json})
        :ok

      %{"branch" => wrong_branch, "result" => 0} ->
        Logger.info 'Wrong branch "#{wrong_branch}", expected "#{branch}"'
        :wrong_branch

      %{"branch" => ^branch, "result" => wrong_result, "result_message" => msg} ->
        Logger.info 'Build not successful, result: #{wrong_result} "#{msg}"'
        :build_not_successful
    end
  end

  def receive_once(socket) do
    :inet.setopts(socket, [{:active, :once}])
    receive do
      {:tcp, ^socket, text} -> {:ok, text}
      after 1000 -> :timeout
    end
  end

  def receive_header(socket, conf),
    do: receive_header(socket, conf.flood_bytes, "")
  def receive_header(socket, flood_countdown, text) do
    {:ok, text_received} = receive_once(socket)
    text = text <> text_received
    case String.split(text, "\r\n\r\n", parts: 2) do
      [header_text, body_start] ->
        header =
          header_text
          |> String.split("\r\n")
          |> Enum.drop(1) # POST ...
          |> Enum.map(fn line ->
              [key, val] = String.split(line, ":", parts: 2)
              {String.downcase(key), String.strip(val)}
            end)
          |> Map.new

        {:ok, header, body_start}

      _ ->
        if flood_countdown < 0 do
          :gen_tcp.close(socket)
          Logger.debug "flooded #{socket}"
          :flooded
        else
          receive_header(socket, flood_countdown - byte_size(text_received), text)
        end
    end
  end

  def receive_payload(socket, body_text, content_length_left) when content_length_left > 0 do
    {:ok, text_received} = receive_once(socket)
    receive_payload(socket, body_text <> text_received, content_length_left - byte_size(text_received))
  end
  def receive_payload(_socket, body_text, _content_length_left) do
    {"payload=", payload} = String.split_at(body_text, byte_size("payload="))
    payload
    |> URI.decode_www_form
    |> Poison.decode!
  end

  # receives until mailbox is empty, then processes last request
  def upgrade_loop(conf) do
    receive do
      {:do_upgrade, new_request} -> __MODULE__.upgrade_loop(conf, new_request)
    end
  end
  def upgrade_loop(conf, last_request) do
    receive do
      {:do_upgrade, new_request} -> __MODULE__.upgrade_loop(conf, new_request)
      after 0 ->
        do_upgrade(conf, last_request)
        __MODULE__.upgrade_loop(conf)
    end
  end

  def do_upgrade(%{branch: branch} = conf, %{"branch" => branch} = json) do
    {short_commit, _} = String.split_at(json["commit"], 7)
    Logger.info 'Upgrading to "#{json["message"]}" (#{json["author_name"]}) #{short_commit} on branch #{branch}, build \##{json["number"]} #{json["build_url"]}'

    cmd_opts = [cd: conf.repo_path, into: IO.stream(:stdio, :line)]

    {_, 0} = System.cmd "git", ["fetch", "origin"], cmd_opts
    {_, 0} = System.cmd "git", ["checkout", "-f", json["commit"]], cmd_opts

    conf.update_func.(json, cmd_opts)

    Logger.info 'Upgrade done: "#{json["message"]}" (#{json["author_name"]}) #{short_commit}'
  end

end
