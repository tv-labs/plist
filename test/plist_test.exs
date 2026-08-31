defmodule PlistTest do
  use ExUnit.Case, async: true

  doctest Plist

  @header """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  """

  defp xml(body), do: @header <> "<plist version=\"1.0\">\n" <> body <> "\n</plist>\n"

  defp dict(body), do: xml("<dict>\n" <> body <> "\n</dict>")

  defp fixture(filename) do
    [File.cwd!(), "test", "fixtures", filename]
    |> Path.join()
    |> File.read!()
    |> Plist.decode!()
  end

  describe "fixtures" do
    test "binary.plist" do
      plist = fixture("binary.plist")

      assert plist["String"] == "foobar"
      assert plist["Number"] == 1234
      assert plist["Array"] == ["A", "B", "C"]
      assert plist["Date"] == ~U[2015-11-17 14:00:59Z]
      assert plist["True"] == true
      assert plist["SomeUID"] == {:uid, 40}
      assert plist[""] == ""
      assert plist["DoubleSpaced"] == "foo  bar"
    end

    test "xml.plist" do
      plist = fixture("xml.plist")

      assert plist["String"] == "foobar"
      assert plist["Number"] == 1234
      assert plist["Float"] == 1234.1234
      assert plist["Array"] == ["A", "B", "C"]
      assert plist["Date"] == ~U[2015-11-17 14:00:59Z]
      assert plist["True"] == true
      assert plist["False"] == false
      assert plist["Base64"] == <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      assert plist["EntityEncoded"] == "Foo & Bar"
      assert plist[""] == ""
      assert plist["DoubleSpaced"] == "foo  bar"
    end

    test "integers.bplist, written by Apple's own encoder via plutil" do
      # CFBinaryPlist writes the 1-, 2- and 4-byte widths unsigned and only the
      # 8-byte width signed, so it never packs a negative into a small width.
      assert fixture("integers.bplist") == %{
               "a_127" => 127,
               "b_200" => 200,
               "c_255" => 255,
               "d_40000" => 40_000,
               "e_neg1" => -1,
               "f_neg42" => -42,
               "g_neg129" => -129
             }
    end

    test "unicode.bplist, written by Apple's own encoder via plutil" do
      # Apple writes non-ASCII text as a 0x6 UTF-16BE string, keeping 0x5 for
      # pure ASCII. Note that a 0x6 length counts UTF-16 code units, so the
      # emoji outside the BMP is stored as a two-unit surrogate pair.
      assert fixture("unicode.bplist") == %{
               "ascii" => "plain",
               "empty" => "",
               "jp" => "日本語",
               "accent" => "café",
               "emoji" => "🎬",
               "quote" => "it’s"
             }
    end

    test "xml.plist preserves non-ASCII characters verbatim" do
      plist = fixture("xml.plist")

      assert plist["UnicσdeKey"] == "foobar"
      assert plist["UnicodeValue"] == "© 2008 – 2016"
    end
  end

  describe "decode/1 with XML" do
    test "decodes an empty dict" do
      assert {:ok, %{}} == Plist.decode(xml("<dict/>"))
    end

    test "decodes strings" do
      assert {:ok, %{"Name" => "John Doe", "City" => "New York"}} ==
               Plist.decode(
                 dict("""
                 <key>Name</key><string>John Doe</string>
                 <key>City</key><string>New York</string>
                 """)
               )
    end

    test "preserves significant whitespace in strings and keys" do
      assert {:ok, %{" spaced key " => "  padded  "}} ==
               Plist.decode(dict("<key> spaced key </key><string>  padded  </string>"))
    end

    test "decodes an empty string" do
      assert {:ok, %{"Empty" => ""}} == Plist.decode(dict("<key>Empty</key><string></string>"))
    end

    test "decodes integers" do
      assert {:ok, %{"Age" => 42, "Negative" => -10}} ==
               Plist.decode(
                 dict("""
                 <key>Age</key><integer>42</integer>
                 <key>Negative</key><integer>-10</integer>
                 """)
               )
    end

    test "decodes reals, including ones written without a decimal point" do
      assert {:ok, %{"Pi" => pi, "Whole" => whole}} =
               Plist.decode(
                 dict("""
                 <key>Pi</key><real>3.14159</real>
                 <key>Whole</key><real>42</real>
                 """)
               )

      assert_in_delta pi, 3.14159, 0.00001
      assert whole == 42.0
    end

    test "decodes booleans" do
      assert {:ok, %{"Enabled" => true, "Disabled" => false}} ==
               Plist.decode(
                 dict("""
                 <key>Enabled</key><true/>
                 <key>Disabled</key><false/>
                 """)
               )
    end

    test "decodes arrays" do
      assert {:ok, %{"Items" => ["one", "two", 3]}} ==
               Plist.decode(
                 dict("""
                 <key>Items</key>
                 <array><string>one</string><string>two</string><integer>3</integer></array>
                 """)
               )
    end

    test "decodes an empty array" do
      assert {:ok, %{"Empty" => []}} == Plist.decode(dict("<key>Empty</key><array/>"))
    end

    test "decodes nested dicts" do
      assert {:ok, %{"Person" => %{"Name" => "Jane", "Address" => %{"City" => "Boston"}}}} ==
               Plist.decode(
                 dict("""
                 <key>Person</key>
                 <dict>
                   <key>Name</key><string>Jane</string>
                   <key>Address</key><dict><key>City</key><string>Boston</string></dict>
                 </dict>
                 """)
               )
    end

    test "decodes base64 data" do
      assert {:ok, %{"Data" => "Hello World"}} ==
               Plist.decode(dict("<key>Data</key><data>SGVsbG8gV29ybGQ=</data>"))
    end

    test "decodes base64 data split across lines" do
      assert {:ok, %{"Data" => "Hello World"}} ==
               Plist.decode(
                 dict("""
                 <key>Data</key>
                 <data>
                   SGVs
                   bG8g
                   V29y
                   bGQ=
                 </data>
                 """)
               )
    end

    test "decodes dates as DateTime" do
      assert {:ok, %{"Created" => ~U[2024-01-15 12:30:00Z]}} ==
               Plist.decode(dict("<key>Created</key><date>2024-01-15T12:30:00Z</date>"))
    end

    test "ignores comments" do
      assert {:ok, %{"K" => "v"}} ==
               Plist.decode(dict("<!-- a comment --><key>K</key><string>v</string>"))
    end

    test "returns an error for invalid XML" do
      assert {:error, %Plist.Error{operation: :decode}} = Plist.decode("not xml at all")
    end

    test "returns an error for an empty plist" do
      assert {:error, %Plist.Error{operation: :decode, reason: :empty_plist}} =
               Plist.decode(xml(""))
    end
  end

  describe "decode/1 with XML containing typographic characters" do
    # These parse only because xmerl is handed bytes rather than codepoints.
    # Passing codepoints makes it reject them as {:bad_character, 8217}.
    for {name, char} <- [
          right_single_quote: "’",
          left_single_quote: "‘",
          left_double_quote: "“",
          right_double_quote: "”",
          en_dash: "–",
          em_dash: "—"
        ] do
      test "preserves #{name}" do
        char = unquote(char)

        assert {:ok, %{"Text" => text}} =
                 Plist.decode(dict("<key>Text</key><string>a#{char}b</string>"))

        assert text == "a" <> char <> "b"
      end
    end

    test "preserves characters outside the sanitizer's table" do
      assert {:ok, %{"Text" => "日本語 © ✓ σ"}} ==
               Plist.decode(dict("<key>Text</key><string>日本語 © ✓ σ</string>"))
    end
  end

  describe "decode/1 with binary plists" do
    test "decodes a bare string" do
      assert {:ok, "hello"} == Plist.decode(Plist.encode_binary!("hello"))
    end

    test "decodes a bare integer" do
      assert {:ok, 42} == Plist.decode(Plist.encode_binary!(42))
    end

    test "round trips integers across every width boundary" do
      for n <- [
            0,
            1,
            127,
            128,
            255,
            256,
            65_535,
            65_536,
            4_294_967_295,
            4_294_967_296,
            -1,
            -42,
            -128,
            -129,
            -32_768,
            -2_147_483_648
          ] do
        assert {:ok, ^n} = Plist.decode(Plist.encode_binary!(n))
      end
    end

    test "writes non-ASCII strings as UTF-16BE, as Apple does" do
      # A 0x5 ASCII string holding UTF-8 bytes reads back as MacRoman in
      # CoreFoundation, so "日本語" would reach Apple as "æ¥æ¬èª".
      assert <<"bplist00", 0x63, 0x65E5::16, 0x672C::16, 0x8A9E::16, _rest::binary>> =
               Plist.encode_binary!("日本語")
    end

    test "keeps pure ASCII strings in the compact 0x5 width" do
      assert <<"bplist00", 0x55, "plain", _rest::binary>> = Plist.encode_binary!("plain")
    end

    test "counts UTF-16 code units, not characters, for astral plane text" do
      # U+1F3AC is a surrogate pair, so the length is 2 rather than 1
      assert <<"bplist00", 0x62, 0xD83C::16, 0xDFAC::16, _rest::binary>> =
               Plist.encode_binary!("🎬")
    end

    test "writes negatives at the 8-byte width, as Apple does" do
      assert <<"bplist00", 0x13, -42::big-signed-64, _rest::binary>> =
               Plist.encode_binary!(-42)
    end

    test "decodes booleans" do
      assert {:ok, true} == Plist.decode(Plist.encode_binary!(true))
      assert {:ok, false} == Plist.decode(Plist.encode_binary!(false))
    end

    test "decodes dates without a configured time zone database" do
      assert {:ok, ~U[2020-05-05 01:02:03Z]} ==
               Plist.decode(Plist.encode_binary!(~U[2020-05-05 01:02:03Z]))
    end

    test "returns an error for a truncated binary plist" do
      assert {:error, %Plist.Error{operation: :decode}} =
               Plist.decode(<<"bplist00", 0x50, 0x05>>)
    end
  end

  describe "decode!/1" do
    test "returns the value on success" do
      assert %{"Test" => "value"} ==
               Plist.decode!(dict("<key>Test</key><string>value</string>"))
    end

    test "raises on failure" do
      assert_raise Plist.Error, ~r/failed to decode plist/, fn -> Plist.decode!("invalid") end
    end
  end

  describe "encode/1" do
    test "encodes an empty map" do
      assert Plist.encode!(%{}) =~ "<dict/>"
    end

    test "encodes scalars" do
      assert Plist.encode!(%{"Name" => "John"}) =~ "<string>John</string>"
      assert Plist.encode!(%{"Count" => 42}) =~ "<integer>42</integer>"
      assert Plist.encode!(%{"Negative" => -100}) =~ "<integer>-100</integer>"
      assert Plist.encode!(%{"Pi" => 3.14}) =~ "<real>3.14</real>"
      assert Plist.encode!(%{"Enabled" => true}) =~ "<true/>"
      assert Plist.encode!(%{"Disabled" => false}) =~ "<false/>"
      assert Plist.encode!(%{"Empty" => nil}) =~ "<string/>"
    end

    test "encodes an empty array" do
      assert Plist.encode!(%{"Empty" => []}) =~ "<array/>"
    end

    test "encodes dates" do
      assert Plist.encode!(%{"At" => ~U[2024-01-15 12:30:00Z]}) =~
               "<date>2024-01-15T12:30:00Z</date>"
    end

    test "encodes naive dates as UTC" do
      assert Plist.encode!(%{"At" => ~N[2024-01-15 12:30:00]}) =~
               "<date>2024-01-15T12:30:00Z</date>"
    end

    test "encodes non-printable binaries as base64 data" do
      assert Plist.encode!(%{"Bytes" => <<0, 1, 2, 255>>}) =~ "<data>AAEC/w==</data>"
    end

    test "encodes {:data, bytes} as base64 data" do
      assert Plist.encode!(%{"Bytes" => {:data, "hello"}}) =~ "<data>aGVsbG8=</data>"
    end

    test "escapes XML metacharacters" do
      xml = Plist.encode!(%{"Text" => "<b> & 'q' \"d\""})

      assert xml =~ "&lt;b&gt; &amp; &apos;q&apos; &quot;d&quot;"
    end

    test "includes the plist header" do
      xml = Plist.encode!(%{})

      assert xml =~ "<?xml version=\"1.0\""
      assert xml =~ "<!DOCTYPE plist"
      assert xml =~ "<plist version=\"1.0\">"
    end

    test "returns an error for an unencodable value" do
      assert {:error, %Plist.Error{operation: :encode}} =
               Plist.encode(%{"Pid" => self()})
    end
  end

  describe "encode!/1" do
    test "raises on failure" do
      assert_raise Plist.Error, ~r/failed to encode plist/, fn ->
        Plist.encode!(%{"Pid" => self()})
      end
    end
  end

  describe "encode_binary/1" do
    test "starts with the bplist00 header" do
      assert <<"bplist00", _rest::binary>> = Plist.encode_binary!(%{"key" => "value"})
    end

    test "encodes UIDs, which XML cannot represent" do
      assert {:ok, {:uid, 40}} == Plist.decode(Plist.encode_binary!({:uid, 40}))
    end

    test "encodes strings longer than the 15-byte inline length" do
      long = String.duplicate("x", 300)

      assert {:ok, ^long} = Plist.decode(Plist.encode_binary!(long))
    end

    test "encodes dicts with more than 15 entries" do
      big = Map.new(1..40, &{"key#{&1}", &1})

      assert {:ok, ^big} = Plist.decode(Plist.encode_binary!(big))
    end

    test "raises on failure" do
      assert_raise Plist.Error, ~r/failed to encode plist/, fn ->
        Plist.encode_binary!(%{"Pid" => self()})
      end
    end
  end

  # The property tests exclude these three from their generators. Pinning them
  # here keeps the exclusions honest: if any of this behaviour changes, a test
  # fails rather than a generator quietly covering less ground.
  describe "documented limits on round tripping" do
    test "nil decodes back as an empty string from XML, and as nil from binary" do
      assert %{"k" => ""} == Plist.decode!(Plist.encode!(%{"k" => nil}))
      assert %{"k" => nil} == Plist.decode!(Plist.encode_binary!(%{"k" => nil}))
    end

    test "sub-second precision is dropped by both encoders" do
      dt = ~U[2024-01-15 12:30:00.500000Z]
      whole = ~U[2024-01-15 12:30:00Z]

      assert %{"k" => whole} == Plist.decode!(Plist.encode!(%{"k" => dt}))
      assert %{"k" => whole} == Plist.decode!(Plist.encode_binary!(%{"k" => dt}))
    end

    test "a fractional date is never emitted, because Apple's parser rejects one" do
      refute Plist.encode!(%{"k" => ~U[2024-01-15 12:30:00.500000Z]}) =~ "00.5"

      assert Plist.encode!(%{"k" => ~U[2024-01-15 12:30:00.500000Z]}) =~
               "<date>2024-01-15T12:30:00Z</date>"
    end

    test "characters XML forbids survive binary but not XML" do
      # plutil writes the raw control character into <string> too, so this
      # matches Apple rather than diverging from it.
      assert %{"k" => "\a"} == Plist.decode!(Plist.encode_binary!(%{"k" => "\a"}))

      assert Plist.encode!(%{"k" => "\a"}) =~ "<string>\a</string>"
      assert {:error, %Plist.Error{}} = Plist.decode(Plist.encode!(%{"k" => "\a"}))
    end
  end

  describe "round trips" do
    @values %{
      "String" => "hello",
      "Unicode" => "日本語 © – ’",
      "Padded" => "  keep me  ",
      "Integer" => 42,
      "Negative" => -7,
      "Float" => 3.25,
      "True" => true,
      "False" => false,
      "Date" => ~U[2024-01-15 12:30:00Z],
      "Array" => ["a", 1, false],
      "Nested" => %{"Users" => [%{"Name" => "Alice", "Age" => 30}]}
    }

    test "through XML" do
      assert {:ok, @values} == @values |> Plist.encode!() |> Plist.decode()
    end

    test "through binary" do
      assert {:ok, @values} == @values |> Plist.encode_binary!() |> Plist.decode()
    end

    test "binary and XML agree" do
      assert Plist.decode!(Plist.encode!(@values)) ==
               Plist.decode!(Plist.encode_binary!(@values))
    end
  end
end
