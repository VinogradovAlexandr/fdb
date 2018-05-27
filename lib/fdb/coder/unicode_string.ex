defmodule FDB.Coder.UnicodeString do
  @behaviour FDB.Coder.Behaviour

  def new do
    %FDB.Coder{
      module: __MODULE__,
      opts: :binary.compile_pattern(<<0x00>>)
    }
  end

  @null <<0x00>>
  @escaped <<0x00, 0xFF>>
  @code <<0x02>>
  @suffix <<0x00>>

  @impl true
  def encode(value, null_pattern) do
    @code <> :binary.replace(value, null_pattern, @escaped, [:global]) <> @suffix
  end

  @impl true
  def decode(@code <> value, _), do: do_decode(value, <<>>)

  defp do_decode(@escaped <> rest, acc), do: do_decode(rest, <<acc::binary, @null>>)
  defp do_decode(@null, acc), do: {acc, <<>>}
  defp do_decode(@null <> rest, acc), do: {acc, rest}

  defp do_decode(<<char::utf8>> <> rest, acc),
    do: do_decode(rest, <<acc::binary, char::utf8>>)
end
