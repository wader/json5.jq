# json5.jq - JSON5 implementation for jq
# https://spec.json5.org/
#
# Copyright (c) 2024 Mattias Wadman
# MIT License
#

def fromjson5:
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

  # TODO: keep track of position?
  def lex:
    def _unescape:
      gsub(
        ( "(?<surrogate>(\\\\u[dD][89a-fA-F][0-9a-fA-F]{2}){2})|"
        + "(?<codepoint>\\\\u[0-9a-fA-F]{4})|"
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
            }[$escape]
          | if not then error("unknown escape: \\\($escape)") else . end
          )
        else error("unreachable")
        end
      );

    def _token:
      def _re($re; f):
        ( . as {$remain}
        | $remain
        | match($re; "m").string
        | f as $token
        | { result: ($token | del(.string_stack))
          , remain: $remain[length:]
          }
        );
      if .remain == "" then empty
      else
        (  _re("^\\s+"; {whitespace: .})
        // _re("^//[^\n]*"; {comment: .})
        // _re("^/\\*.*\\*/"; {comment: .})
        // _re("^\\.[_a-zA-Z][_a-zA-Z0-9]*"; {index: .[1:]})
        # 0x123
        // _re("^[+-]?0[xX][0-9a-fA-F]+"; {number: .})
        # 1.23, .123, 123e2, 1.23e2, 123E2, 1.23e+2, 1.23E-2 or 123
        // _re("^[+-]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.[0-9]*|[0-9]+)(?:[eE][-\\+]?[0-9]+)?"; {number: .})
        // _re("^[+-]?(?:NaN|Infinity)"; {number: .})
        # TODO: single quote string
        # TODO: multi line string
        // _re("^\"(?:[^\"\\\\]|\\\\.)*\""; .[1:-1] | _unescape | {string: .})
        // _re("^'(?:[^\\'])*'"; .[1:-1] | _unescape | {string: .})
        // _re("^[_a-zA-Z][_a-zA-Z0-9]*"; {ident: .})
        // _re("^:";      {colon: .})
        // _re("^,";      {comma: .})
        // _re("^\\[";    {lsquare: .})
        // _re("^\\]";    {rsquare: .})
        // _re("^{";      {lcurly: .})
        // _re("^}";      {rcurly: .})
        // error("unknown token: '\(.remain[0:100])'")
        )
      end;
    def _lex:
      ( { remain: .
        , result: {whitespace: ""}
        }
      | recurse(_token)
      | .result
      | select((.whitespace // .comment) | not)
      );
    [_lex];

  def parse:
    def _consume(f): select(.[0] | f) | .[1:];
    def _optional(f):
      ( f
      // [., null]
      );
    def _repeat(f):
      def _f:
        ( f as [$rest, $v]
        | [$rest, $v]
        , ( $rest
          | _f
          )
        );
      ( . as $c
      | [_f]
      | if length > 0 then [.[-1][0], map(.[1])]
        else [$c, []]
        end
      );
    def _keyword($name): _consume(.ident == $name);

    def _p($type):
      def _scalar($type; c; f):
        ( . as [$first]
        | _consume(c)
        | [ .
          , { term:
                ( $first
                | f
                | .type = $type
                )
            }
          ]
        );

      # {<keyval>...} where keyval is:
      # name
      # "name"
      # $name
      # name: <term>
      # "name": <term>
      # <subquery>: <term>
      def _object:
        ( _consume(.lcurly)
        | _repeat(
            # TODO:
            # string interpolated key
            #   {"\(...)"} -> {"\(...)"": .["\(...)"]}
            #   {"\(...)": ...} -> {"\(...)"": ...}
            # multi query val:
            #    term | ...
            ( ( def _colon_val:
                  ( _consume(.colon)
                  | _p("term") as [$rest, $val]
                  | $rest
                  | [ .
                    , { queries: [$val]
                      }
                    ]
                  );
                (
                  # {a: ...} -> {a: ...}
                  ( .[0] as $ident
                  | _consume(.ident)
                  | _colon_val as [$rest, $val]
                  | $rest
                  | [ .
                    , { key: $ident.ident
                      , val: $val
                      }
                    ]
                  )
                //
                  # {"a": ...} -> {a: ...}
                  ( _p("string") as [$rest, $string]
                  | $rest
                  | _colon_val as [$rest, $val]
                  | $rest
                  | [ .
                    , { key_string:
                          {str: $string.term.str}
                      , val: $val
                      }
                    ]
                  )
                )
              ) as [$rest, $key_vals]
            | $rest
            | ( if .[0].rcurly then
                  # keep it to make repeat finish and consumed it below
                  [$rest, null]
                else
                  # or there must be a comma
                  ( _consume(.comma)
                  | [., null]
                  )
                end
              ) as [$rest, $_]
            | [$rest, $key_vals]
            )
          ) as [$rest, $key_vals]
        | $rest
        | _consume(.rcurly)
        | [ .
          , { term:
                { type: "TermTypeObject"
                , object:
                    {key_vals: $key_vals}
                }
            }
          ]
        );

      # [<query>]
      def _array:
        ( _consume(.lsquare)
        | _repeat(
            ( _p("term") as [$rest, $term]
            | $rest
            | ( if .[0].rsquare then
                  # keep it to make repeat finish and consumed it below
                  [$rest, null]
                else
                  # or there must be a comma
                  ( _consume(.comma)
                  | [., null]
                  )
                end
              ) as [$rest, $_]
            | [$rest, $term]
            )
          ) as [$rest, $terms]
        | $rest
        | _consume(.rsquare)
        | [ .
          , { term:
                { type: "TermTypeArray"
                , array:
                    {query: $terms}
                }
            }
          ]
        );

      # "abc"
      def _string_simple:
        _scalar("TermTypeString"; .string; {str: .string});

      def _string:
        ( _string_simple
        );

      ( .# debug({_p: $type})
      | if $type == "query" then
          # used by _op_prec_climb, exist to fix infinite recursion
          # does not include infix operators
          ( ( if length == 0 then
                [ .
                , { term:
                      {type: "TermTypeIdentity"}
                  }
                ]
              else
                _p("term")
              end
            ) as [$rest, $query]
          | $query
          | [$rest, .]
          )
        elif $type == "term" then
          ( (  _p("true")
            // _p("false")
            // _p("null")
            // _p("number")
            // _p("string")
            // _p("array")
            // _p("object")
            ) as [$rest, $term]
          | $rest
          | [., $term]
          )
        elif $type == "true" then _scalar("TermTypeTrue"; .ident == "true"; .)
        elif $type == "false" then _scalar("TermTypeFalse"; .ident == "false"; .)
        elif $type == "null" then _scalar("TermTypeNull"; .ident == "null"; .)
        elif $type == "number" then _scalar("TermTypeNumber"; .number; {number: .number})
        elif $type == "string" then _string
        elif $type == "array" then _array
        elif $type == "object" then _object
        else error("unknown type \($type)")
        end
      );
    ( ( _p("query")
      | if .[0] != [] then error("tokens left: \(.)") else . end
      | .[1]
      )
    // error("parse error: \(.)")
    );

  def _tonumber:
    if startswith("+") then .[1:] | _tonumber
    elif startswith("-") then .[1:] | -_tonumber
    elif startswith("0x") or startswith("0X") then .[2:] | _fromhex
    elif . == "NaN" then nan
    elif . == "Infinity" then -infinite
    else tonumber
    end;

  def _f:
    ( . as $v
    | .term.type
    | if . == "TermTypeNull" then null
      elif . == "TermTypeTrue" then true
      elif . == "TermTypeFalse" then false
      elif . == "TermTypeString" then $v.term.str
      elif . == "TermTypeNumber" then $v.term.number | _tonumber
      elif . == "TermTypeObject" then
        ( $v.term.object.key_vals // []
        | map(
            { key: (.key_string.str // .key)
            , value: (.val.queries[0] | _f)
            }
          )
        | from_entries
        )
      elif . == "TermTypeArray" then
        ( $v.term.array.query
        | map(_f)
        )
      else error("unknown term")
      end
    );
  try
    (lex | parse | _f)
  catch
    error("fromjson only supports constant literals \(.)");
