# moonbit-community/lexical_edit

Replaces the first matching MoonBit token sequence from left to right. Whitespace, line breaks, comments, and automatically inserted semicolons between tokens are ignored; explicit semicolons remain significant.

```mbt check
///|
test "replace across whitespace and comments" {
  let result = @lexical_edit.lexical_edit(
    old="a + b",
    new="sum",
    "let x = a // comment\n  + b\n",
  )
  assert_eq(result, "let x = sum\n")
}
```

Leading and trailing whitespace and comments in `old` do not affect match locations. The replacement range starts at the beginning of the first matched token and ends at the end of the last matched token. Whitespace and comments within the range are removed with the replacement; text outside it is preserved verbatim. `new` is inserted verbatim, without parsing or indentation adjustment; an empty string deletes the match.

```mbt check
///|
test "delete the first match" {
  assert_eq(
    @lexical_edit.lexical_edit(old=" + b", new="", "a + b + b"),
    "a  + b",
  )
}
```

Matching requires identical token kinds and original text, except that trailing lexer-recognized whitespace in attribute tokens is ignored, including Unicode whitespace. These trailing characters remain part of the replacement range and are removed with the attribute. ASCII line endings (LF, CRLF, or CR) after a final attribute are outside its token and are preserved.

```mbt check
///|
test "replace an attribute with different trailing whitespace" {
  assert_eq(
    @lexical_edit.lexical_edit(
      old="#deprecated(\"reason\")  ",
      new="#deprecated(\"updated\")",
      "#deprecated(\"reason\")\t\u3000\nfn f {}",
    ),
    "#deprecated(\"updated\")\nfn f {}",
  )
}
```

Literal values are not normalized. Whitespace inside strings, interpolated strings, and the remaining attribute text must match exactly, and these tokens are not searched recursively. Ordinary MoonBit lexical rules apply. Code fragments need not form complete syntax, and wildcards are not supported.

The function raises `LEditError`:

| Error | Meaning |
| --- | --- |
| `EmptyOld` | `old` contains no meaningful tokens after ignoring whitespace, comments, and automatic semicolons. |
| `OldLexError(offset~, message~)` | `old` contains a lexical error. |
| `InputLexError(offset~, message~)` | The entire `input` contains a lexical error, including errors after the match. |
| `NotFound` | No contiguous token sequence matches. |

First, `old` is tokenized and validated, then the entire `input` is tokenized and validated, and finally a match is sought. Lexical errors use the first diagnostic returned by the lexer, without using recovery tokens or falling back to text matching. `offset` is a UTF-16 code unit offset relative to the start of the corresponding `StringView`, and `message` preserves the lexer's diagnostic text.

```mbt check
///|
test "handle an empty pattern" {
  try @lexical_edit.lexical_edit(old="// comment", new="x", "a") catch {
    error => assert_true(error is @lexical_edit.LEditError::EmptyOld)
  } noraise {
    _ => fail("expected EmptyOld")
  }
}
```
