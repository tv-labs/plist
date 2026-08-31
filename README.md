# Plist

An Elixir library to encode and decode Apple's property list formats, both XML
and binary (`bplist00`).

## Installation

```elixir
def deps do
  [{:plist, "~> 1.0"}]
end
```

## Usage

Decoding detects the format from the header:

```elixir
{:ok, plist} = path |> File.read!() |> Plist.decode()

# or let it raise
plist = path |> File.read!() |> Plist.decode!()
```

Encoding is explicit about which format you want:

```elixir
{:ok, xml} = Plist.encode(%{"CFBundleIdentifier" => "com.example.app"})
{:ok, binary} = Plist.encode_binary(%{"CFBundleIdentifier" => "com.example.app"})
```

Failures come back as a `Plist.Error` carrying the operation and reason:

```elixir
{:error, %Plist.Error{operation: :decode, reason: :empty_plist}} = Plist.decode(xml)
```

## Types

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

UIDs are object references used by `NSKeyedArchiver`. They have no XML
equivalent, so `{:uid, n}` round-trips only through `encode_binary/1`.

Binary output writes dict keys in sorted order, and does not share equal
objects between slots — the output is valid but larger than Apple's for input
with heavy repetition.

## Upgrading from 0.x

`decode/1` now returns a tuple, dates decode to `DateTime`, and UIDs decode to
`{:uid, n}`. See [CHANGELOG.md](CHANGELOG.md) for the full list.

## License

MIT
