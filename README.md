# json5.jq

[JSON5](https://json5.org) implementation for [jq](https://jqlang.github.io/jq/).

> [!WARNING]  
> Performance is probably horrible and error handling non-existing.

Code it mostly a stripped down and modified version of [jqjq](https://github.com/wader/jqjq).

Compatible with
[jq](https://jqlang.org/),
[gojq](https://github.com/itchyny/gojq)
and [jaq](https://github.com/01mf02/jaq).

## Usage
```sh
$ cat example.json5
{
  // comments
  unquoted: 'and you can quote me on that',
  singleQuotes: 'I can use "double quotes" here',
  lineBreaks: "Look, Mom! \
No \\n's!",
  hexadecimal: 0xdecaf,
  leadingDecimalPoint: .8675309, andTrailing: 8675309.,
  positiveSign: +1,
  trailingComma: 'in objects', andIn: ['arrays',],
  "backwardsCompatible": "with JSON",
}

# -Rs to read content of example.json5 as a string, don't parse it as JSON
# -L . adds current directory to library path (where json5.jq is)
# include "json5" to load json5.jq
# fromjson5 to use included function on input string
$ jq -Rs -L . 'include "json5"; fromjson5' example.json5
{
  "unquoted": "and you can quote me on that",
  "singleQuotes": "I can use \"double quotes\" here",
  "lineBreaks": "Look, Mom! No \\n's!",
  "hexadecimal": 912559,
  "leadingDecimalPoint": 0.8675309,
  "andTrailing": 8675309,
  "positiveSign": 1,
  "trailingComma": "in objects",
  "andIn": [
    "arrays"
  ],
  "backwardsCompatible": "with JSON"
}

$ jq -Rs -L . 'include "json5"; fromjson5 | .hexadecimal + .positiveSign' example.json5
912560
```
Put content of `json5.jq` in `~/.jq` to make it be included automatically and you can do:
```sh
$ jq -Rs fromjson5.a <<< '{a:0x123}'
291
```

## Run tests

```sh
make test
```

## TODO
- Cleanup jqjq remains
- Line/column on error
- Less hacky `{NaN: 123}` support
- Verify supported whitespace. Now uses `\s` regexp

# Resources

- https://spec.json5.org/
- https://262.ecma-international.org/5.1/
- https://github.com/json5/json5-tests
