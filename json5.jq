# json5.jq - JSON5 implementation for jq
# https://spec.json5.org/
#
# Copyright (c) 2024 Mattias Wadman
# MIT License
#

def fromjson5:
  # Risk considerations for parser hardening:
  # - Input confusion or partial-token acceptance can silently misparse data.
  #   Mitigation: strict token regexes and full token consumption check.
  # - Escapes in identifiers/strings can bypass naive matching.
  #   Mitigation: explicit unescape handling with unknown-escape rejection.
  # - Invalid numeric formats (legacy octal-like literals) can be accepted unexpectedly.
  #   Mitigation: numeric lexer rules reject leading-zero decimal forms.
  def _fromhex:
    def _fromradix($base; tonum):
      reduce explode[] as $c (
        0;
        . * $base + ($c | tonum)
      );
    _fromradix(
      16;
      if . >= 48 and . <= 57 then .-48 # 0-9
      elif . >= 97 and . <= 102 then .-97+10 # a-f
      else .-65+10 # A-F
      end
    );

  def _tonumber:
    if startswith("+") then .[1:] | _tonumber
    elif startswith("-") then .[1:] | -_tonumber
    elif startswith("0x") or startswith("0X") then .[2:] | _fromhex
    # jaq tonumber throws on ".123" and "123."
    elif startswith(".") then "0" + . | tonumber
    elif endswith(".") then .[:-1] | tonumber
    elif . == "NaN" then nan
    elif . == "Infinity" then infinite
    else tonumber
    end;

  def lex:
    def _advance_position($line; $column; $text):
      ($text | gsub("\r\n|\r|\u2028|\u2029"; "\n")) as $normalized
      | ($normalized | split("\n")) as $segments
      | if ($segments | length) == 1 then
          {line: $line, column: ($column + ($segments[0] | length))}
        else
          { line: ($line + (($segments | length) - 1))
          , column: (($segments[-1] | length) + 1)
          }
        end;

    def _unescape:
      gsub(
        ( "(?<surrogate>(\\\\u[dD][89a-fA-F][0-9a-fA-F]{2}){2})|"
        + "(?<codepoint>\\\\u[0-9a-fA-F]{4})|"
        + "(?<hex>\\\\x[0-9a-fA-F]{2})|"
        + "(?<newline_escape>\\\\(?:\\r\\n|[\\n\\r\\u2028\\u2029]))|"
        + "(?<escape>\\\\.)"
        );
        if .surrogate then
          # surrogate pair \uD83D\uDCA9 -> 💩
          ( .surrogate
          | ([.[2:6], .[8:] | _fromhex]) as [$hi,$lo]
          # translate surrogate hi/lo pair values into codepoint
          # (hi-0xd800<<10) + (lo-0xdc00) + 0x10000
          | [($hi-55296)*1024 + ($lo-56320) + 65536]
          | implode
          )
        elif .codepoint then
          # codepoint \u006a -> j
          ( .codepoint[2:]
          | [_fromhex]
          | implode
          )
        elif .hex then
          # Two-digit hexadecimal escapes map to U+00XX codepoints.
          ( .hex[2:]
          | [_fromhex]
          | implode
          )
        elif .newline_escape then
            ""
        elif .escape then
          # escape \n -> \n
          ( .escape[1:] as $escape
          | { "n": "\n"
            , "r": "\r"
            , "t": "\t"
            , "f": "\f"
            , "b": "\b"
            , "\"": "\""
            , "/": "/"
            , "\\": "\\"
            , "'": "'"
            }[$escape]
          | if not then error("unknown escape: \\\($escape)") else . end
          )
        else error("unreachable")
        end
      );

    # JSON5 forbids raw line terminators in string literals.
    # Keep escaped line continuations, reject any remaining line terminators.
    def _reject_unescaped_line_terminator:
      . as $raw
      | ( $raw
        # Strip escaped backslashes first so "\\\n" is not mistaken for a
        # line continuation. After this, a remaining "\\<line terminator>"
        # is always a real continuation and can be removed safely.
        | gsub("\\\\\\\\"; "")
        | gsub("\\\\(?:\\r\\n|[\\n\\r\u2028\u2029])"; "")
        | if test("[\\n\\r\u2028\u2029]") then
            error("unescaped line terminator in string")
          else
            $raw
          end
        );

    def _token:
      def _re($re; f):
        ( . as $state
        | ($state.remain | match($re; "").string) as $matched
        | ($matched | f) as $token
        | (_advance_position($state.line; $state.column; $matched)) as $next
        | { result: ($token + {pos: {offset: $state.offset, line: $state.line, column: $state.column}})
          , remain: $state.remain[($matched | length):]
          , offset: ($state.offset + ($matched | length))
          , line: $next.line
          , column: $next.column
          }
        );
      if .remain == "" then empty
      else
        ( _re("^(?:[\u0009\u000B\u000C\u0020\u00A0\uFEFF\u000A\u000D\u2028\u2029\u1680\u2000-\u200A\u202F\u205F\u3000])+"; {whitespace: .})
        # // comment
        // _re("^//[^\\n\\r\u2028\u2029]*"; {comment: .})
        # /* comment */
        // _re("^/\\*[\\s\\S]*?\\*/"; {comment: .})
        # +/- 0X123, 0x123
        // _re("^[+-]?0[xX][0-9a-fA-F]+"; {number: .})
        # +/- 1.23, .123, 123e2, 1.23e2, 123E2, 1.23e+2, 1.23E-2, 123, 123.
        # Reject legacy leading-zero forms (010, 080, +0123, ...).
        // _re("^[+-]?(?:(?:0|[1-9][0-9]*)(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][-\\+]?[0-9]+)?"; {number: .})
        # signed NaN/Infinity numeric literals
        // _re("^[+-](?:NaN|Infinity)"; {number: .})
        # \n and \r are excluded directly in the regex char class. Unicode
        # line separators (U+2028/U+2029) are rejected in
        # _reject_unescaped_line_terminator after tokenization.
        # "abc"
        // _re("^\"(?:\\\\(?:\\r\\n|\\n|\\r)|[^\"\\\\\n\r]|\\\\.)*?\""; .[1:-1] | _reject_unescaped_line_terminator | _unescape | {string: .})
        # 'abc'
        // _re("^'(?:\\\\(?:\\r\\n|\\n|\\r)|[^'\\\\\n\r]|\\\\.)*?'"; .[1:-1] | _reject_unescaped_line_terminator | _unescape | {string: .})
        # ES5.1-ish IdentifierName support (Unicode categories + \uXXXX escapes).
        // _re("^(?:[$_\\p{L}\\p{Nl}]|\\\\u[0-9a-fA-F]{4})(?:[$_\\p{L}\\p{Nl}\\p{Mn}\\p{Mc}\\p{Nd}\\p{Pc}\\u200C\\u200D]|\\\\u[0-9a-fA-F]{4})*"; . | _unescape | {ident: .})
        // _re("^:";      {colon: .})
        // _re("^,";      {comma: .})
        // _re("^\\[";    {lsquare: .})
        // _re("^\\]";    {rsquare: .})
        // _re("^\\{";    {lcurly: .})
        // _re("^\\}";    {rcurly: .})
        // error("unknown token at line \(.line), column \(.column): '\(.remain[0:100])'")
        )
      end;
    ( [ # Seed state carries the initial position. It is also the eof position
        # for empty input because recurse(_token) emits only this state then.
        { remain: .
        , offset: 0
        , line: 1
        , column: 1
        , result: {whitespace: ""}
        }
        | recurse(_token)
      ] ) as $states
    | { tokens: ($states | map(.result) | map(select((.whitespace // .comment) | not)))
      , eof_pos: ($states[-1] | {offset, line, column})
      };

  def parse:
    .eof_pos as $eof_pos
    | .tokens
    | def _token($name): (length > 0 and .[0][$name]);
      def _error_at($message):
        if length == 0 then
          error("\($message) at line \($eof_pos.line), column \($eof_pos.column)")
        else
          error("\($message) at line \(.[0].pos.line), column \(.[0].pos.column)")
        end;
    def _expect($name):
      if _token($name) then .[1:]
      else _error_at("expected token \($name)")
      end;

    def _parse_term:
      # [<term>, ...] with optional trailing comma
      def _parse_array_values($acc):
        _parse_term as [$rest, $value]
        | $rest as $after_value
        | if ($after_value | _token("rsquare")) then
            [$after_value[1:], ($acc + [$value])]
          elif ($after_value | _token("comma")) then
            ($after_value[1:] as $after_comma
            | if ($after_comma | _token("rsquare")) then
                [$after_comma[1:], ($acc + [$value])]
              else
                $after_comma | _parse_array_values($acc + [$value])
              end
            )
          else
            ($after_value | _error_at("expected ',' or ']' after array value"))
          end;

      def _parse_array:
        (.[1:] as $after_lsquare
        | if ($after_lsquare | _token("rsquare")) then
            [$after_lsquare[1:], []]
          else
            $after_lsquare | _parse_array_values([])
          end
        );

      def _parse_member:
        if _token("ident") then
          .[0].ident as $key
          | .[1:]
          | _expect("colon")
          | _parse_term as [$rest, $value]
          | [$rest, {key: $key, value: $value}]
        elif _token("string") then
          .[0].string as $key
          | .[1:]
          | _expect("colon")
          | _parse_term as [$rest, $value]
          | [$rest, {key: $key, value: $value}]
        else
          _error_at("expected object key")
        end;

      # {name or "name": <term>, ...} with optional trailing comma
      def _parse_members($acc):
        _parse_member as [$rest, $member]
        | $rest as $after_member
        | if ($after_member | _token("rcurly")) then
            [$after_member[1:], ($acc + [$member])]
          elif ($after_member | _token("comma")) then
            ($after_member[1:] as $after_comma
            | if ($after_comma | _token("rcurly")) then
                [$after_comma[1:], ($acc + [$member])]
              else
                $after_comma | _parse_members($acc + [$member])
              end
            )
          else
            ($after_member | _error_at("expected ',' or '}' after object member"))
          end;

      def _parse_object:
        (.[1:] as $after_lcurly
        | if ($after_lcurly | _token("rcurly")) then
            [$after_lcurly[1:], {}]
          else
            ($after_lcurly
            | _parse_members([]) as [$rest, $members]
            | [$rest, ($members | from_entries)]
            )
          end
        );

      if length == 0 then
        _error_at("unexpected eof")
      elif .[0].ident == "true" then
        [.[1:], true]
      elif .[0].ident == "false" then
        [.[1:], false]
      elif .[0].ident == "null" then
        [.[1:], null]
      elif .[0].ident == "NaN" then
        [.[1:], nan]
      elif .[0].ident == "Infinity" then
        [.[1:], infinite]
      elif (.[0] | has("number")) then
        [.[1:], (.[0].number | _tonumber)]
      elif .[0].string then
        [.[1:], .[0].string]
      elif .[0].lsquare then
        _parse_array
      elif .[0].lcurly then
        _parse_object
      else
        _error_at("unexpected token in value")
      end;

    ( _parse_term as [$rest, $value]
    | if $rest != [] then
        error("tokens left at line \($rest[0].pos.line), column \($rest[0].pos.column): \($rest)")
      else
        $value
      end
    );

  try
    (lex | parse)
  catch
    error("fromjson5 only supports constant literals: \(.)");
