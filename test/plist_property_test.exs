defmodule PlistPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Generators stay inside what a plist can actually represent. The values that
  # deliberately do not round-trip -- nil, sub-second dates, and strings holding
  # characters XML forbids -- are excluded here and pinned by explicit tests in
  # PlistTest instead, so a shrinking failure always means a real defect.

  defp plist_string do
    # `String.printable?` accepts control characters that XML rejects, so the
    # generated codepoints are restricted to what both formats can carry.
    StreamData.string([?\t, ?\n, ?\r, 0x20..0xD7FF, 0xE000..0xFFFD, 0x10000..0x10FFFF])
  end

  defp plist_datetime do
    map(integer(0..4_102_444_800), &DateTime.from_unix!/1)
  end

  defp scalar do
    one_of([
      plist_string(),
      integer(),
      float(),
      boolean(),
      plist_datetime(),
      # Non-printable binaries take the <data> path
      map(binary(), fn bin -> if String.printable?(bin), do: <<0, bin::binary>>, else: bin end)
    ])
  end

  defp plist_value do
    tree(scalar(), fn child ->
      one_of([list_of(child, max_length: 5), map_of(plist_string(), child, max_length: 5)])
    end)
  end

  property "round trips through the binary format" do
    check all(value <- plist_value()) do
      assert {:ok, ^value} = value |> Plist.encode_binary!() |> Plist.decode()
    end
  end

  property "round trips through the XML format" do
    check all(value <- plist_value()) do
      assert {:ok, ^value} = value |> Plist.encode!() |> Plist.decode()
    end
  end

  property "both formats decode to the same value" do
    check all(value <- plist_value()) do
      assert Plist.decode!(Plist.encode!(value)) == Plist.decode!(Plist.encode_binary!(value))
    end
  end

  property "binary output always carries the bplist00 header and a 32-byte trailer" do
    check all(value <- plist_value()) do
      binary = Plist.encode_binary!(value)

      assert <<"bplist00", _rest::binary>> = binary
      assert byte_size(binary) >= 8 + 32
    end
  end

  property "decoding never raises, whatever bytes it is handed" do
    check all(bytes <- binary()) do
      assert match?({:ok, _}, Plist.decode(bytes)) or
               match?({:error, %Plist.Error{}}, Plist.decode(bytes))
    end
  end

  property "a truncated binary plist is reported rather than raising" do
    check all(
            value <- plist_value(),
            binary = Plist.encode_binary!(value),
            cut <- integer(0..(byte_size(binary) - 1))
          ) do
      assert match?({:ok, _}, Plist.decode(binary_part(binary, 0, cut))) or
               match?({:error, %Plist.Error{}}, Plist.decode(binary_part(binary, 0, cut)))
    end
  end

  # plutil is the reference implementation. Round-trip properties compare this
  # library against itself, so they cannot see a convention both sides get wrong
  # in the same direction -- which is exactly how the integer signedness and
  # UTF-16 string bugs survived. This compares against a foreign reader instead.
  if System.find_executable("plutil") do
    property "plutil reads back what encode_binary/1 writes" do
      check all(value <- map_of(plist_string(), scalar(), max_length: 5), max_runs: 40) do
        assert {:ok, ^value} = value |> Plist.encode_binary!() |> via_plutil()
      end
    end

    property "plutil reads back what encode/1 writes" do
      check all(value <- map_of(plist_string(), scalar(), max_length: 5), max_runs: 40) do
        assert {:ok, ^value} = value |> Plist.encode!() |> via_plutil()
      end
    end

    # Hand a plist to plutil, have it rewrite the file in the other format, and
    # decode that. Anything we encoded in a way Apple misreads comes back wrong.
    defp via_plutil(encoded) do
      path = Path.join(System.tmp_dir!(), "plist_prop_#{System.unique_integer([:positive])}")
      File.write!(path, encoded)

      try do
        case System.cmd("plutil", ["-convert", "binary1", path], stderr_to_stdout: true) do
          {_, 0} -> path |> File.read!() |> Plist.decode()
          {output, code} -> {:error, {:plutil_exit, code, output}}
        end
      after
        File.rm(path)
      end
    end
  end
end
