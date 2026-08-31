# Changelog

## v1.0.0

Adds encoding, and reworks the decoding API. Every change below is breaking.

### Added

- `encode/1` and `encode!/1` produce an XML plist.
- `encode_binary/1` and `encode_binary!/1` produce a binary plist, including the
  UID objects that `NSKeyedArchiver` payloads need.
- `decode!/1`, which raises rather than returning a tuple.
- `Plist.Error`, carrying `:operation` (`:encode` or `:decode`) and `:reason`.

### Changed

- `decode/1` returns `{:ok, value}` or `{:error, %Plist.Error{}}` instead of
  returning the value directly and raising on bad input. Use `decode!/1` for
  the old shape.
- Dates decode to `DateTime` rather than a string. Previously XML dates came
  back as the raw text (`"2015-11-17T14:00:59Z"`) and binary dates as a
  reformatted string (`"2015-11-17 14:00:59 +0000"`).
- Binary UID objects decode to `{:uid, n}` rather than `%{"CF$UID" => n}`.
- A plist whose root is not a `<plist>` element with exactly one child now
  returns `{:error, ...}` with reason `:empty_plist` or `:invalid_plist`.
- XML parse failures no longer log through xmerl; the reason is on the returned
  `Plist.Error`.
- Requires Elixir 1.15+.

### Fixed

- Binary integers decode with the correct sign. CFBinaryPlist stores the 1-, 2-
  and 4-byte widths unsigned and only the 8-byte width signed; every width was
  previously read unsigned, so `-42` decoded as `214`. Negative integers are now
  also written at the 8-byte width, matching Apple's encoder.
- Non-ASCII strings encode to binary plists as UTF-16BE (`0x6`) rather than
  being packed into the ASCII width (`0x5`) as raw UTF-8. CoreFoundation reads
  a `0x5` string as MacRoman, so `"日本語"` previously reached Apple as
  `"æ¥æ¬èª"`. Lengths on those strings count UTF-16 code units, so text
  outside the BMP is stored as a surrogate pair.
- Non-ASCII characters in XML plists survive decoding. xmerl is handed bytes
  rather than codepoints, so a document declaring `encoding="UTF-8"` decodes its
  own multi-byte characters instead of rejecting them.

### Removed

- `parse/1`, deprecated since 0.0.6. Use `decode/1`.
- `Plist.XML` and `Plist.Binary`, which were never public.
