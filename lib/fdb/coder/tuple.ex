defmodule FDB.Coder.Tuple do
  @behaviour FDB.Coder.Behaviour

  def new(coders) do
    %FDB.Coder{module: __MODULE__, opts: Tuple.to_list(coders)}
  end

  @impl true
  def encode(values, coders) do
    values = Tuple.to_list(values)
    validate_length!(values, coders)

    do_encode(coders, values)
  end

  @impl true
  def decode(rest, coders) do
    Enum.reduce(coders, {{}, rest}, fn coder, {values, rest} ->
      {elem, rest} = coder.module.decode(rest, coder.opts)
      {Tuple.append(values, elem), rest}
    end)
  end

  @impl true
  def range(nil, _), do: {<<0x00>>, <<0xFF>>}

  def range(values, coders) do
    values = Tuple.to_list(values)

    if Enum.empty?(values) do
      {<<0x00>>, <<0xFF>>}
    else
      encoded = do_encode(values, Enum.take(coders, length(values)))
      {encoded <> <<0x00>>, encoded <> <<0xFF>>}
    end
  end

  defp do_encode(coders, values) do
    Enum.zip(coders, values)
    |> Enum.map(fn {coder, value} ->
      coder.module.encode(value, coder.opts)
    end)
    |> Enum.join(<<>>)
  end

  defp validate_length!(values, coders) do
    actual = length(values)
    expected = length(coders)

    if actual != expected do
      raise ArgumentError,
            "Invalid value: expected tuple with length #{expected}, got #{List.to_tuple(values)}"
    end
  end
end