defmodule Plist do
  @moduledoc """
  Encode and decode Apple property lists, in both XML and binary (`bplist00`)
  formats.

  Decoding auto-detects the format from the header. Encoding is explicit:
  `encode/1` produces XML, `encode_binary/1` produces a binary plist.

  ## Type mapping

  | plist        | Elixir              |
  | ------------ | ------------------- |
  | `<string>`   | `String.t()`        |
  | `<integer>`  | `integer()`         |
  | `<real>`     | `float()`           |
  | `<true/>`    | `true`              |
  | `<false/>`   | `false`             |
  | `<date>`     | `DateTime.t()`      |
  | `<data>`     | `binary()`          |
  | `<array>`    | `list()`            |
  | `<dict>`     | `map()`             |
  | UID (binary) | `{:uid, integer()}` |

  Binary plists are needed for `NSKeyedArchiver` payloads, which encode object
  references as UIDs. Those have no XML equivalent, so `{:uid, n}` round-trips
  only through `encode_binary/1`.

  ## What does not round-trip

  Three values encode to something that decodes back differently:

    * `nil` has no plist equivalent. It encodes to an empty `<string>` in XML
      and to the binary null object, so it decodes back as `""` from XML and as
      `nil` from binary.

    * Dates are whole seconds. Apple's XML parser rejects a `<date>` carrying a
      fractional second, so sub-second precision is dropped by both encoders.

    * Strings holding characters that XML forbids, such as `\\a`, are written
      literally into `<string>`. The result is not well-formed XML and cannot be
      decoded again. `plutil` emits the same thing, so this matches Apple rather
      than working around it; use `encode_binary/1` for such values.
  """

  import Bitwise

  alias Plist.Error

  @type t ::
          String.t()
          | integer()
          | float()
          | boolean()
          | nil
          | DateTime.t()
          | {:uid, non_neg_integer()}
          | [t()]
          | %{optional(String.t()) => t()}

  # Binary plist type markers (high nibble)
  @type_int 0x10
  @type_real 0x20
  @type_date 0x30
  @type_data 0x40
  @type_ascii 0x50
  @type_unicode 0x60
  @type_uid 0x80
  @type_array 0xA0
  @type_dict 0xD0

  # Seconds between the Unix epoch and the Apple epoch (2001-01-01T00:00:00Z)
  @apple_epoch 978_307_200

  @header_size 8

  @plist_header """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  """

  @doc """
  Decode an XML or binary plist, detecting the format from the header.

  ## Examples

      iex> Plist.decode(~s|<plist version="1.0"><string>hi</string></plist>|)
      {:ok, "hi"}

  """
  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(binary) when is_binary(binary) do
    case binary do
      <<"bplist00", _rest::binary>> -> decode_binary_plist(binary)
      _ -> decode_xml_plist(binary)
    end
  rescue
    e ->
      {:error, Error.exception(operation: :decode, reason: e)}
  catch
    :exit, reason ->
      {:error, Error.exception(operation: :decode, reason: {:xml_parse_error, reason})}
  end

  @doc """
  Decode an XML or binary plist, raising `Plist.Error` on failure.
  """
  @spec decode!(binary()) :: t()
  def decode!(binary) do
    case decode(binary) do
      {:ok, value} -> value
      {:error, %Error{} = error} -> raise error
    end
  end

  # -- binary decoding --------------------------------------------------------

  defp decode_binary_plist(<<"bplist00", _rest::binary>> = binary) do
    size = byte_size(binary)

    # Trailer is the last 32 bytes
    trailer_offset = size - 32
    <<_objects::binary-size(^trailer_offset), trailer::binary-32>> = binary

    <<
      _unused::binary-6,
      offset_size::8,
      object_ref_size::8,
      num_objects::64,
      top_object::64,
      offset_table_offset::64
    >> = trailer

    offset_table_size = num_objects * offset_size

    <<_::binary-size(^offset_table_offset), offset_table::binary-size(^offset_table_size),
      _::binary>> = binary

    offsets = parse_offset_table(offset_table, offset_size, [])

    context = %{
      binary: binary,
      offsets: offsets,
      object_ref_size: object_ref_size
    }

    {:ok, parse_object(context, Enum.at(offsets, top_object))}
  rescue
    e ->
      {:error, Error.exception(operation: :decode, reason: {:binary_plist_error, e})}
  end

  defp parse_offset_table(<<>>, _size, acc), do: Enum.reverse(acc)

  defp parse_offset_table(data, size, acc) do
    <<offset::size(^size)-unit(8), rest::binary>> = data
    parse_offset_table(rest, size, [offset | acc])
  end

  defp parse_object(context, offset) do
    <<_::binary-size(^offset), marker::8, rest::binary>> = context.binary
    dispatch_type(band(marker, 0xF0), band(marker, 0x0F), marker, rest, context)
  end

  defp dispatch_type(0x00, info, _marker, _rest, _context), do: parse_singleton(info)
  defp dispatch_type(0x10, info, _marker, rest, _context), do: parse_int(rest, info)
  defp dispatch_type(0x20, info, _marker, rest, _context), do: parse_real(rest, info)
  defp dispatch_type(0x30, _info, _marker, rest, _context), do: parse_date(rest)
  defp dispatch_type(0x40, info, _marker, rest, context), do: parse_data(context, rest, info)

  defp dispatch_type(0x50, info, _marker, rest, context),
    do: parse_ascii_string(context, rest, info)

  defp dispatch_type(0x60, info, _marker, rest, context),
    do: parse_unicode_string(context, rest, info)

  defp dispatch_type(0x80, info, _marker, rest, _context), do: parse_uid(rest, info)
  defp dispatch_type(0xA0, info, _marker, rest, context), do: parse_array(context, rest, info)
  defp dispatch_type(0xD0, info, _marker, rest, context), do: parse_dict(context, rest, info)
  defp dispatch_type(_type, _info, marker, _rest, _context), do: {:unknown, marker}

  # 0x0F is the fill byte
  defp parse_singleton(0x0F), do: nil
  defp parse_singleton(0x00), do: nil
  defp parse_singleton(0x08), do: false
  defp parse_singleton(0x09), do: true
  defp parse_singleton(n), do: {:singleton, n}

  # CFBinaryPlist stores the 1-, 2- and 4-byte widths unsigned, and only the
  # 8-byte width signed. Reading every width as signed turns a byte-sized 255
  # into -1.
  defp parse_int(data, info), do: parse_sized_int(data, bsl(1, info))

  defp parse_sized_int(data, byte_count) when byte_count >= 8 do
    <<value::big-signed-size(^byte_count)-unit(8), _::binary>> = data
    value
  end

  defp parse_sized_int(data, byte_count) do
    <<value::big-unsigned-size(^byte_count)-unit(8), _::binary>> = data
    value
  end

  defp parse_real(data, 2) do
    <<value::float-32, _::binary>> = data
    value
  end

  defp parse_real(data, 3) do
    <<value::float-64, _::binary>> = data
    value
  end

  defp parse_date(data) do
    <<seconds::float-64, _::binary>> = data
    DateTime.from_unix!(@apple_epoch + trunc(seconds))
  end

  defp parse_data(context, data, info) do
    {length, data} = get_length(context, data, info)
    <<bytes::binary-size(^length), _::binary>> = data
    bytes
  end

  defp parse_ascii_string(context, data, info) do
    {length, data} = get_length(context, data, info)
    <<str::binary-size(^length), _::binary>> = data
    str
  end

  defp parse_unicode_string(context, data, info) do
    {length, data} = get_length(context, data, info)
    byte_length = length * 2
    <<str::binary-size(^byte_length), _::binary>> = data
    :unicode.characters_to_binary(str, {:utf16, :big})
  end

  defp parse_uid(data, info) do
    byte_count = info + 1
    <<uid::big-size(^byte_count)-unit(8), _::binary>> = data
    {:uid, uid}
  end

  defp parse_array(context, data, info) do
    {length, data} = get_length(context, data, info)
    refs = parse_refs(data, context.object_ref_size, length, [])
    Enum.map(refs, &parse_object(context, Enum.at(context.offsets, &1)))
  end

  defp parse_dict(context, data, info) do
    {length, data} = get_length(context, data, info)
    ref_size = context.object_ref_size
    key_refs = parse_refs(data, ref_size, length, [])
    skip_size = length * ref_size
    <<_::binary-size(^skip_size), value_data::binary>> = data
    value_refs = parse_refs(value_data, ref_size, length, [])

    keys = Enum.map(key_refs, &parse_object(context, Enum.at(context.offsets, &1)))
    values = Enum.map(value_refs, &parse_object(context, Enum.at(context.offsets, &1)))

    keys |> Enum.zip(values) |> Map.new()
  end

  defp parse_refs(_data, _ref_size, 0, acc), do: Enum.reverse(acc)

  defp parse_refs(data, ref_size, count, acc) do
    <<ref::big-size(^ref_size)-unit(8), rest::binary>> = data
    parse_refs(rest, ref_size, count - 1, [ref | acc])
  end

  defp get_length(_context, data, 0x0F) do
    # Length lives in the next int object, and is always unsigned
    <<int_marker::8, rest::binary>> = data
    byte_count = bsl(1, band(int_marker, 0x0F))
    <<length::big-unsigned-size(^byte_count)-unit(8), remaining::binary>> = rest
    {length, remaining}
  end

  defp get_length(_context, data, info), do: {info, data}

  # -- XML decoding -----------------------------------------------------------

  # xmerl is handed a list of *bytes*, not codepoints: the document declares
  # `encoding="UTF-8"`, so xmerl decodes multi-byte characters itself. Passing
  # codepoints instead makes it reject anything above U+007F as a bad character.
  #
  # `quiet: true` keeps xmerl from logging a fatal error of its own; the caller
  # gets the failure back as a `Plist.Error` instead.
  defp decode_xml_plist(xml_binary) do
    {doc, _} = :xmerl_scan.string(:binary.bin_to_list(xml_binary), comments: false, quiet: true)
    decode_root(doc)
  end

  defp decode_root(doc) do
    case find_child_elements(doc) do
      [plist_content] -> {:ok, decode_value(plist_content)}
      [] -> {:error, Error.exception(operation: :decode, reason: :empty_plist)}
      _ -> {:error, Error.exception(operation: :decode, reason: :invalid_plist)}
    end
  end

  # xmerl records are tuples:
  # xmlElement: {:xmlElement, name, _, _, _, _, _, attributes, content, _, _, _}
  # xmlText: {:xmlText, _, _, _, value, _}

  defp decode_value({:xmlElement, :dict, _, _, _, _, _, _, content, _, _, _}) do
    content
    |> Enum.filter(&element?/1)
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [{:xmlElement, :key, _, _, _, _, _, _, key_content, _, _, _}, val_el] ->
        {get_text(key_content), decode_value(val_el)}
    end)
  end

  defp decode_value({:xmlElement, :array, _, _, _, _, _, _, content, _, _, _}) do
    content
    |> Enum.filter(&element?/1)
    |> Enum.map(&decode_value/1)
  end

  defp decode_value({:xmlElement, :string, _, _, _, _, _, _, content, _, _, _}) do
    get_text(content)
  end

  defp decode_value({:xmlElement, :integer, _, _, _, _, _, _, content, _, _, _}) do
    content |> get_text() |> String.trim() |> String.to_integer()
  end

  defp decode_value({:xmlElement, :real, _, _, _, _, _, _, content, _, _, _}) do
    content |> get_text() |> String.trim() |> parse_real()
  end

  defp decode_value({:xmlElement, true, _, _, _, _, _, _, _, _, _, _}), do: true
  defp decode_value({:xmlElement, false, _, _, _, _, _, _, _, _, _, _}), do: false

  defp decode_value({:xmlElement, :data, _, _, _, _, _, _, content, _, _, _}) do
    content |> get_text() |> String.replace(~r/\s/, "") |> Base.decode64!()
  end

  defp decode_value({:xmlElement, :date, _, _, _, _, _, _, content, _, _, _}) do
    content |> get_text() |> String.trim() |> parse_datetime()
  end

  defp find_child_elements({:xmlElement, _, _, _, _, _, _, _, content, _, _, _}) do
    Enum.filter(content, &element?/1)
  end

  defp element?({:xmlElement, _, _, _, _, _, _, _, _, _, _, _}), do: true
  defp element?(_), do: false

  # Whitespace inside <string> and <key> is significant, so this must not trim.
  # Callers expecting a number or a date trim at the call site.
  defp get_text(content) do
    content
    |> Enum.filter(fn
      {:xmlText, _, _, _, _, _} -> true
      _ -> false
    end)
    |> Enum.map_join("", fn {:xmlText, _, _, _, value, _} -> to_string(value) end)
  end

  defp parse_real(str) do
    case Float.parse(str) do
      {float, ""} -> float
      _ -> String.to_integer(str) * 1.0
    end
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> str
    end
  end

  # -- XML encoding -----------------------------------------------------------

  @doc """
  Encode a value as an XML plist.

  ## Examples

      iex> {:ok, xml} = Plist.encode(%{"key" => "value"})
      iex> xml =~ "<key>key</key>"
      true

  """
  @spec encode(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def encode(value) do
    {:ok,
     @plist_header <> "<plist version=\"1.0\">\n" <> encode_value(value, 0) <> "\n</plist>\n"}
  rescue
    e ->
      {:error, Error.exception(operation: :encode, reason: e)}
  end

  @doc """
  Encode a value as an XML plist, raising `Plist.Error` on failure.
  """
  @spec encode!(t()) :: String.t()
  def encode!(value) do
    case encode(value) do
      {:ok, xml} -> xml
      {:error, %Error{} = error} -> raise error
    end
  end

  # Apple's XML plist parser rejects a <date> carrying a fractional second, so
  # these truncate. Binary dates are whole seconds too, which keeps the two
  # formats in agreement.
  defp encode_value(%DateTime{} = dt, indent) do
    ind(indent) <> "<date>#{dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()}</date>"
  end

  defp encode_value(%NaiveDateTime{} = dt, indent) do
    iso = dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
    ind(indent) <> "<date>#{iso}Z</date>"
  end

  defp encode_value(map, indent) when is_map(map) do
    if map_size(map) == 0 do
      ind(indent) <> "<dict/>"
    else
      inner =
        Enum.map_join(map, "\n", fn {k, v} ->
          ind(indent + 1) <> "<key>#{escape(to_string(k))}</key>\n" <> encode_value(v, indent + 1)
        end)

      ind(indent) <> "<dict>\n" <> inner <> "\n" <> ind(indent) <> "</dict>"
    end
  end

  defp encode_value([], indent), do: ind(indent) <> "<array/>"

  defp encode_value(list, indent) when is_list(list) do
    inner = Enum.map_join(list, "\n", &encode_value(&1, indent + 1))
    ind(indent) <> "<array>\n" <> inner <> "\n" <> ind(indent) <> "</array>"
  end

  defp encode_value({:data, bytes}, indent) when is_binary(bytes) do
    ind(indent) <> "<data>#{Base.encode64(bytes, padding: true)}</data>"
  end

  defp encode_value(str, indent) when is_binary(str) do
    if String.printable?(str) do
      ind(indent) <> "<string>#{escape(str)}</string>"
    else
      ind(indent) <> "<data>#{Base.encode64(str, padding: true)}</data>"
    end
  end

  defp encode_value(int, indent) when is_integer(int) do
    ind(indent) <> "<integer>#{int}</integer>"
  end

  defp encode_value(float, indent) when is_float(float) do
    ind(indent) <> "<real>#{float}</real>"
  end

  defp encode_value(true, indent), do: ind(indent) <> "<true/>"
  defp encode_value(false, indent), do: ind(indent) <> "<false/>"
  defp encode_value(nil, indent), do: ind(indent) <> "<string/>"

  defp ind(level), do: String.duplicate("\t", level)

  defp escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # -- binary encoding --------------------------------------------------------

  @doc """
  Encode a value as a binary plist.

  Binary plists are more compact than XML and support the UID references that
  `NSKeyedArchiver` payloads need.

  ## Examples

      iex> {:ok, binary} = Plist.encode_binary(%{"key" => "value"})
      iex> match?(<<"bplist00", _rest::binary>>, binary)
      true

      iex> Plist.encode_binary!({:uid, 5}) |> Plist.decode()
      {:ok, {:uid, 5}}

  """
  @spec encode_binary(t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_binary(value) do
    # Objects are collected children-first, so after reversing the root is last
    # and carries the highest index.
    objects = value |> flatten_objects([]) |> Enum.reverse()

    num_objects = length(objects)
    object_ref_size = ref_size_for_count(num_objects)

    {encoded_objects, offsets} = encode_objects(objects, object_ref_size)

    offset_table_offset = @header_size + byte_size(encoded_objects)
    offset_size = ref_size_for_count(offset_table_offset)
    offset_table = build_offset_table(offsets, offset_size)

    trailer =
      build_trailer(
        offset_size,
        object_ref_size,
        num_objects,
        num_objects - 1,
        offset_table_offset
      )

    {:ok, "bplist00" <> encoded_objects <> offset_table <> trailer}
  rescue
    e ->
      {:error, Error.exception(operation: :encode, reason: e)}
  end

  @doc """
  Encode a value as a binary plist, raising `Plist.Error` on failure.
  """
  @spec encode_binary!(t()) :: binary()
  def encode_binary!(value) do
    case encode_binary(value) do
      {:ok, binary} -> binary
      {:error, %Error{} = error} -> raise error
    end
  end

  # Collect every object into a list, children before parents, in reverse order.
  # Equal values are emitted once per occurrence rather than shared, so output is
  # correct but larger than necessary for input with heavy repetition.
  defp flatten_objects(%DateTime{} = dt, objects), do: [{:date, dt} | objects]
  defp flatten_objects(%NaiveDateTime{} = dt, objects), do: [{:date, dt} | objects]

  defp flatten_objects(map, objects) when is_map(map) do
    objects =
      Enum.reduce(map, objects, fn {k, v}, acc ->
        flatten_objects(v, flatten_objects(k, acc))
      end)

    [{:dict, map} | objects]
  end

  defp flatten_objects(list, objects) when is_list(list) do
    [{:array, list} | Enum.reduce(list, objects, &flatten_objects/2)]
  end

  defp flatten_objects({:uid, _uid} = uid_tuple, objects), do: [uid_tuple | objects]
  defp flatten_objects(other, objects), do: [other | objects]

  defp ref_size_for_count(count) when count < 256, do: 1
  defp ref_size_for_count(count) when count < 65_536, do: 2
  defp ref_size_for_count(count) when count < 4_294_967_296, do: 4
  defp ref_size_for_count(_), do: 8

  # Encode every object, returning {binary, offsets}. Offsets are relative to
  # the start of the file, so they include the 8-byte header.
  defp encode_objects(objects, object_ref_size) do
    index_map =
      objects
      |> Enum.with_index()
      |> Map.new(fn {obj, idx} -> {obj_key(obj), idx} end)

    {encoded, offsets, _offset} =
      Enum.reduce(objects, {<<>>, [], @header_size}, fn obj, {bin, offs, offset} ->
        encoded_obj = encode_binary_object(obj, index_map, object_ref_size)
        {bin <> encoded_obj, [offset | offs], offset + byte_size(encoded_obj)}
      end)

    {encoded, Enum.reverse(offsets)}
  end

  # Index-map key, so a raw value and its flattened form resolve to the same slot
  defp obj_key({:dict, map}), do: {:dict, map}
  defp obj_key({:array, list}), do: {:array, list}
  defp obj_key({:date, dt}), do: {:date, dt}
  defp obj_key({:uid, uid}), do: {:uid, uid}
  defp obj_key(%DateTime{} = dt), do: {:date, dt}
  defp obj_key(%NaiveDateTime{} = dt), do: {:date, dt}
  defp obj_key(map) when is_map(map), do: {:dict, map}
  defp obj_key(list) when is_list(list), do: {:array, list}
  defp obj_key(other), do: other

  defp encode_binary_object(nil, _index_map, _ref_size), do: <<0x00>>
  defp encode_binary_object(false, _index_map, _ref_size), do: <<0x08>>
  defp encode_binary_object(true, _index_map, _ref_size), do: <<0x09>>

  defp encode_binary_object({:uid, uid}, _index_map, _ref_size) do
    byte_count = int_byte_count(uid)
    <<@type_uid ||| byte_count - 1, encode_int_bytes(uid, byte_count)::binary>>
  end

  # Only the 8-byte width is signed, so a negative has to be written at full
  # width even when its magnitude would fit in one byte.
  defp encode_binary_object(int, _index_map, _ref_size) when is_integer(int) and int < 0 do
    <<@type_int ||| 3, int::big-signed-64>>
  end

  defp encode_binary_object(int, _index_map, _ref_size) when is_integer(int) do
    power = int |> int_byte_count() |> int_size_power()
    <<@type_int ||| power, encode_int_bytes(int, bsl(1, power))::binary>>
  end

  defp encode_binary_object(float, _index_map, _ref_size) when is_float(float) do
    <<@type_real ||| 3, float::float-64>>
  end

  defp encode_binary_object({:date, %DateTime{} = dt}, _index_map, _ref_size) do
    <<@type_date ||| 3, DateTime.to_unix(dt) - @apple_epoch::float-64>>
  end

  defp encode_binary_object({:date, %NaiveDateTime{} = dt}, index_map, ref_size) do
    utc = DateTime.from_naive!(dt, "Etc/UTC")
    encode_binary_object({:date, utc}, index_map, ref_size)
  end

  defp encode_binary_object(str, _index_map, _ref_size) when is_binary(str) do
    cond do
      not String.printable?(str) ->
        encode_with_length(@type_data, byte_size(str), str)

      :unicode.bin_is_7bit(str) ->
        encode_with_length(@type_ascii, byte_size(str), str)

      true ->
        # The ASCII width cannot carry these bytes -- Apple reads a 0x5 string as
        # MacRoman, so UTF-8 in one comes back mojibake. Non-ASCII text goes in a
        # 0x6 string as UTF-16BE, whose length counts code units, not bytes.
        utf16 = :unicode.characters_to_binary(str, :utf8, {:utf16, :big})
        encode_with_length(@type_unicode, div(byte_size(utf16), 2), utf16)
    end
  end

  defp encode_binary_object({:array, list}, index_map, ref_size) do
    refs =
      list
      |> Enum.map(&encode_int_bytes(Map.fetch!(index_map, obj_key(&1)), ref_size))
      |> IO.iodata_to_binary()

    encode_with_length(@type_array, length(list), refs)
  end

  defp encode_binary_object({:dict, map}, index_map, ref_size) do
    sorted = Enum.sort_by(map, fn {k, _v} -> k end)
    ref = &encode_int_bytes(Map.fetch!(index_map, obj_key(&1)), ref_size)

    key_refs = sorted |> Enum.map(fn {k, _v} -> ref.(k) end) |> IO.iodata_to_binary()
    value_refs = sorted |> Enum.map(fn {_k, v} -> ref.(v) end) |> IO.iodata_to_binary()

    encode_with_length(@type_dict, map_size(map), key_refs <> value_refs)
  end

  defp encode_with_length(type_marker, len, data) when len < 15 do
    <<type_marker ||| len>> <> data
  end

  defp encode_with_length(type_marker, len, data) do
    power = len |> int_byte_count() |> int_size_power()

    <<type_marker ||| 0x0F, @type_int ||| power, encode_int_bytes(len, bsl(1, power))::binary>> <>
      data
  end

  defp encode_int_bytes(int, 1), do: <<int::big-8>>
  defp encode_int_bytes(int, 2), do: <<int::big-16>>
  defp encode_int_bytes(int, 4), do: <<int::big-32>>
  defp encode_int_bytes(int, 8), do: <<int::big-64>>

  # Minimum unsigned width. Only ever called for counts, lengths, UIDs and
  # non-negative integers; negatives are written at the full 8-byte width.
  defp int_byte_count(0), do: 1

  defp int_byte_count(n) when n > 0 do
    bits = :erlang.ceil(:math.log2(n + 1))
    max(div(bits + 7, 8), 1)
  end

  # Power of two for an int size: 0 = 1 byte, 1 = 2 bytes, 2 = 4 bytes, 3 = 8 bytes
  defp int_size_power(1), do: 0
  defp int_size_power(2), do: 1
  defp int_size_power(n) when n <= 4, do: 2
  defp int_size_power(_), do: 3

  defp build_offset_table(offsets, offset_size) do
    offsets
    |> Enum.map(&encode_int_bytes(&1, offset_size))
    |> IO.iodata_to_binary()
  end

  defp build_trailer(offset_size, object_ref_size, num_objects, top_object, offset_table_offset) do
    <<
      0::48,
      offset_size::8,
      object_ref_size::8,
      num_objects::64,
      top_object::64,
      offset_table_offset::64
    >>
  end
end
