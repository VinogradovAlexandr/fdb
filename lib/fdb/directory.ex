defmodule FDB.Directory do
  alias FDB.Coder.{
    Subspace,
    Identity,
    ByteString,
    DirectoryVersion,
    Integer,
    UnicodeString,
    Tuple,
    LittleEndianInteger
  }

  alias FDB.Transaction
  alias FDB.KeySelectorRange
  alias FDB.Directory.HighContentionAllocator
  alias FDB.Directory.Node

  defstruct [
    :node_subspace,
    :content_subspace,
    :allow_manual_prefixes,
    :root_node,
    :node,
    :database,
    :node_name_coder,
    :node_layer_coder,
    :version_coder,
    :prefix_coder,
    :hca_coder,
    :content_coder,
    :parent_directory
  ]

  @directory_version {1, 0, 0}

  def new(options \\ %{}) do
    node_subspace = Map.get(options, :node_subspace, Subspace.new(<<0xFE>>))

    node_name_coder =
      Transaction.Coder.new(
        Subspace.concat(
          node_subspace,
          Subspace.new(
            "",
            Tuple.new({ByteString.new(), Integer.new(), UnicodeString.new()}),
            Identity.new()
          )
        ),
        Identity.new()
      )

    node_layer_coder =
      Transaction.Coder.new(
        Subspace.concat(
          node_subspace,
          Subspace.new(
            "",
            Tuple.new({ByteString.new(), ByteString.new()}),
            Identity.new()
          )
        ),
        Identity.new()
      )

    prefix_coder =
      Transaction.Coder.new(
        Subspace.concat(
          node_subspace,
          Subspace.new(
            "",
            Tuple.new({ByteString.new(), Identity.new()}),
            Identity.new()
          )
        ),
        Identity.new()
      )

    root_node = %Node{prefix: node_subspace.opts.prefix, path: []}

    hca_coder =
      Transaction.Coder.new(
        Subspace.concat(
          node_subspace,
          Subspace.new(root_node.prefix, Identity.new(), ByteString.new())
        )
        |> Subspace.concat(
          Subspace.new("hca", Tuple.new({Integer.new(), Integer.new()}), ByteString.new())
        ),
        LittleEndianInteger.new(64)
      )

    version_coder =
      Transaction.Coder.new(
        Subspace.concat(
          node_subspace,
          Subspace.new("", Tuple.new({ByteString.new(), ByteString.new()}))
        ),
        DirectoryVersion.new()
      )

    content_subspace = Map.get(options, :content_subspace, Subspace.new(<<>>))

    content_coder =
      Transaction.Coder.new(
        Subspace.concat(
          content_subspace,
          Subspace.new(
            "",
            Identity.new(),
            Identity.new()
          )
        ),
        Identity.new()
      )

    %__MODULE__{
      node_subspace: node_subspace,
      content_subspace: content_subspace,
      allow_manual_prefixes: Map.get(options, :allow_manual_prefixes, false),
      root_node: root_node,
      node_name_coder: node_name_coder,
      version_coder: version_coder,
      prefix_coder: prefix_coder,
      hca_coder: hca_coder,
      node_layer_coder: node_layer_coder,
      content_coder: content_coder,
      node: root_node
    }
  end

  def partition_root(directory) do
    node = directory.node

    %{
      new(%{
        node_subspace: Subspace.new(node.prefix <> <<0xFE>>),
        content_subspace: Subspace.new(directory.content_subspace.opts.prefix <> node.prefix)
      })
      | parent_directory: directory
    }
  end

  defp same_partition?(destination_parent, source) do
    destination = Node.follow_partition(destination_parent)
    destination.root_node.prefix == source.root_node.prefix
  end

  def list(directory, tr, path \\ []) do
    check_version(directory, tr, false)
    directory = Node.follow_partition(directory)

    case Node.find(directory, tr, path) do
      nil ->
        raise ArgumentError, "The directory does not exist"

      directory ->
        Node.subdirectories(directory, tr)
        |> Enum.map(&Node.name/1)
    end
  end

  def tree(directory, tr) do
    check_version(directory, tr, false)
    print_tree(%{directory | node: directory.root_node}, tr)
  end

  defp print_tree(directory, tr, path \\ [], depth \\ 0) do
    for name <- list(directory, tr, path) do
      dir = open(directory, tr, path ++ [name])
      IO.puts(inspect(String.duplicate("  ", depth) <> "//" <> name <> ":" <> dir.node.layer))
      print_tree(directory, tr, path ++ [name], depth + 1)
    end
  end

  def open(directory, tr, path, options \\ %{}) do
    check_version(directory, tr, false)
    directory = Node.follow_partition(directory)

    if Node.root?(directory, path) do
      raise ArgumentError, "The root directory cannot be opened."
    end

    case Node.find(directory, tr, path) do
      nil ->
        raise ArgumentError, "The directory does not exist"

      directory ->
        check_layer(directory, Map.get(options, :layer))
        directory
    end
  end

  def exists?(directory, tr, path \\ []) do
    check_version(directory, tr, false)

    !!Node.find(directory, tr, path)
  end

  def create(directory, tr, path, options \\ %{}) do
    check_version(directory, tr, false)
    directory = Node.follow_partition(directory)

    if Node.root?(directory, path) do
      raise ArgumentError, "The root directory cannot be opened."
    end

    case Node.find(directory, tr, path) do
      directory when not is_nil(directory) ->
        raise ArgumentError, "The directory already exists"

      nil ->
        path = directory.node.path ++ path
        directory = %{directory | node: directory.root_node}
        do_create(directory, tr, path, options)
    end
  end

  def create_or_open(directory, tr, path, options \\ %{}) do
    check_version(directory, tr, false)
    directory = Node.follow_partition(directory)

    prefix = Map.get(options, :prefix)

    if prefix != nil do
      raise ArgumentError, "Cannot specify a prefix when calling create_or_open."
    end

    if Node.root?(directory, path) do
      raise ArgumentError, "The root directory cannot be opened."
    end

    case Node.find(directory, tr, path) do
      directory when not is_nil(directory) ->
        check_layer(directory, Map.get(options, :layer))
        directory

      nil ->
        path = directory.node.path ++ path
        directory = %{directory | node: directory.root_node}
        do_create(directory, tr, path, options)
    end
  end

  def move_to(directory, tr, new_path) do
    check_version(directory, tr, true)
    root_directory = %{directory | node: directory.root_node}
    from = Node.find(directory, tr, [])

    cond do
      is_nil(from) -> raise ArgumentError, "The source directory does not exist."
      Node.root?(from, [], false) -> raise ArgumentError, "The root directory cannot be moved."
      true -> :ok
    end

    old_path = from.node.path
    new_parent_path = Enum.drop(new_path, -1)

    if old_path == Enum.take(new_path, length(old_path)) do
      raise ArgumentError,
            "The desination directory cannot be a subdirectory of the source directory."
    end

    to = Node.find(root_directory, tr, new_path)

    if to do
      raise ArgumentError, "The destination directory already exists. Remove it first."
    end

    to_parent = Node.find(root_directory, tr, new_parent_path)

    if !to_parent do
      raise ArgumentError,
            "The parent directory of the destination directory does not exist. Create it first."
    end

    if !same_partition?(to_parent, from) do
      raise ArgumentError,
            "Cannot move between partitions."
    end

    :ok = Node.remove(from, tr)

    Node.create_subdirectory(to_parent, tr, %{
      name: List.last(new_path),
      prefix: from.node.prefix,
      layer: from.node.layer
    })
  end

  def remove(directory, tr, path \\ []) do
    check_version(directory, tr, true)
    directory = Node.find(directory, tr, path)

    cond do
      is_nil(directory) ->
        raise ArgumentError, "The directory does not exist."

      Node.root?(directory, [], false) ->
        raise ArgumentError, "The root directory cannot be removed."

      true ->
        :ok = Node.remove_all(directory, tr)
    end
  end

  def remove_if_exists(directory, tr, path \\ []) do
    check_version(directory, tr, true)
    directory = Node.find(directory, tr, path)

    cond do
      is_nil(directory) ->
        false

      Node.root?(directory, [], false) ->
        raise ArgumentError, "The root directory cannot be removed."

      true ->
        :ok = Node.remove_all(directory, tr)
        true
    end
  end

  defp do_create(directory, tr, path, options) do
    check_version(directory, tr, true)
    prefix = Map.get(options, :prefix)
    layer = Map.get(options, :layer, "")

    if !directory.allow_manual_prefixes && prefix != nil do
      raise ArgumentError, "Cannot specify a prefix unless manual prefixes are enabled."
    end

    prefix =
      cond do
        prefix ->
          if !prefix_free?(directory, tr, prefix) do
            raise ArgumentError, "The given prefix #{inspect(prefix)} is already in use."
          else
            prefix
          end

        true ->
          prefix =
            directory.content_subspace.opts.prefix <>
              HighContentionAllocator.allocate(directory, tr)

          unless Transaction.get_range(tr, KeySelectorRange.starts_with(prefix), %{limit: 1})
                 |> Enum.empty?() do
            raise ArgumentError,
                  "The database has keys stored at the prefix chosen by the automatic prefix allocator: #{
                    inspect(prefix)
                  }."
          end

          unless prefix_free?(directory, tr, prefix) do
            raise ArgumentError,
                  "The directory layer has manually allocated prefixes that conflict with the automatic prefix allocator."
          end

          prefix
      end

    parent_path = Enum.drop(path, -1)

    parent =
      if parent_path == [] do
        %{directory | node: directory.root_node}
      else
        create_or_open(directory, tr, parent_path)
      end

    unless parent do
      raise ArgumentError, "The parent directory does not exist."
    end

    Node.create_subdirectory(parent, tr, %{
      prefix: prefix,
      name: List.last(path),
      layer: layer
    })
  end

  def prefix_free?(directory, tr, prefix) do
    prefix && byte_size(prefix) > 0 && Node.prefix_free?(directory, tr, prefix)
  end

  defp check_version(directory, tr, write_access) do
    coder = directory.version_coder
    version = Transaction.get(tr, {directory.root_node.prefix, "version"}, %{coder: coder})

    case version do
      nil when write_access ->
        :ok =
          Transaction.set(tr, {directory.root_node.prefix, "version"}, @directory_version, %{
            coder: coder
          })

      nil when not write_access ->
        :ok

      {major, _, _} when major != 1 ->
        raise ArgumentError,
              "Cannot load directory with version #{inspect(version)} using directory layer #{
                inspect(@directory_version)
              }"

      {_, minor, _} when minor != 0 and write_access ->
        raise ArgumentError,
              "Directory with version #{inspect(version)} is read-only when opened using directory layer #{
                inspect(@directory_version)
              }"

      _ ->
        :ok
    end
  end

  defp check_layer(directory, layer) do
    node = directory.node

    if layer && layer != "" && node.layer != layer do
      raise ArgumentError, "The directory was created with an incompatible layer."
    end

    :ok
  end
end
