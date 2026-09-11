///|
fn edit_error(
  old~ : StringView,
  new~ : StringView,
  input : StringView,
) -> @lexical_edit.LEditError raise {
  try @lexical_edit.lexical_edit(old~, new~, input) catch {
    error => error
  } noraise {
    _ => fail("expected lexical_edit to raise")
  }
}

///|
test "whitespace, line endings, indentation and automatic semicolons" {
  for input in ["a+b", "a \t+ b", "a\n+\n b", "a\r\n  +\r\n\tb"] {
    assert_eq(@lexical_edit.lexical_edit(old="a + b", new="sum", input), "sum")
  }
  assert_eq(@lexical_edit.lexical_edit(old="a b", new="x", "a\nb"), "x")
  assert_eq(@lexical_edit.lexical_edit(old="a\nb", new="x", "a b"), "x")
}

///|
test "comments inside the match are removed and outside text is preserved" {
  assert_eq(
    @lexical_edit.lexical_edit(
      old=" // pattern\n a + b // end",
      new="sum",
      "// before\n  a // inside\n + // more\n b  // after\n",
    ),
    "// before\n  sum  // after\n",
  )
  assert_eq(
    @lexical_edit.lexical_edit(old="a b", new="x", "a\n/// doc\nb"),
    "x",
  )
}

///|
test "first match at beginning middle end and overlapping candidates" {
  for
    (input, expected) in [
      ("a+b c", "x c"),
      ("c a+b d", "c x d"),
      ("c a+b", "c x"),
    ] {
    assert_eq(@lexical_edit.lexical_edit(old="a+b", new="x", input), expected)
  }
  assert_eq(@lexical_edit.lexical_edit(old="a+b", new="x", "a+b a+b"), "x a+b")
  assert_eq(@lexical_edit.lexical_edit(old="a a", new="x", "a a a"), "x a")
  assert_eq(@lexical_edit.lexical_edit(old="a a b", new="x", "a a a b"), "a x")
}

///|
test "replacement is verbatim and may be empty or lexically invalid" {
  assert_eq(
    @lexical_edit.lexical_edit(old="a+b", new="\n  x\n\ty\n", "  a+b  "),
    "  \n  x\n\ty\n  ",
  )
  assert_eq(@lexical_edit.lexical_edit(old="a+b", new="", "c a+b d"), "c  d")
  assert_eq(@lexical_edit.lexical_edit(old="a", new="`", "a"), "`")
}

///|
test "empty patterns are rejected before input validation" {
  for old in ["", " \t\r\n", "// comment", "/// doc\n // comment\n"] {
    let result = edit_error(old~, new="x", "`")
    assert_true(result is @lexical_edit.LEditError::EmptyOld)
  }
}

///|
test "token boundaries and spellings must match" {
  for
    (old, input) in [
      ("foo", "foobar"),
      ("foo", "Foo"),
      ("foo", "// foo\nbar"),
      ("foo", "\"foo\""),
      ("a+b", "a-b"),
      ("a+b", "a+c"),
      ("1", "01"),
      ("1.0", "1.00"),
      (".0", ".00"),
      ("\"a b\"", "\"a  b\""),
      ("\"a\"", "\"\\u0061\""),
      ("a b", "a;b"),
      ("a;b", "a\nb"),
      ("a", ""),
      ("a b", "a"),
      ("a", "// a"),
      ("field", ".field"),
      (".field", "field"),
    ] {
    let result = edit_error(old~, new="x", input)
    assert_true(result is @lexical_edit.LEditError::NotFound)
  }
  assert_eq(@lexical_edit.lexical_edit(old="a;b", new="x", "a ; b"), "x")
}

///|
test "interpolation and attributes are indivisible and location independent" {
  for token in ["\"value \\{a + b}\"", "#deprecated(\"reason\")"] {
    assert_eq(
      @lexical_edit.lexical_edit(old=token, new="x", "  \{token}"),
      "  x",
    )
  }
  for
    (old, input) in [
      ("a + b", "\"value \\{a + b}\""),
      ("\"value \\{a+b}\"", "\"value \\{a + b}\""),
      ("#deprecated(\"reason\")", "#deprecated( \"reason\" )"),
    ] {
    assert_true(
      edit_error(old~, new="x", input) is @lexical_edit.LEditError::NotFound,
    )
  }
}

///|
test "attribute trailing spaces match and are removed" {
  let attribute = "#deprecated(\"reason\")"
  for (old_suffix, input_suffix) in [("  ", ""), ("", "  "), ("  ", " \t ")] {
    for ending in ["", "\nfn f {}", "\r\nfn f {}", "\rfn f {}"] {
      assert_eq(
        @lexical_edit.lexical_edit(
          old="\{attribute}\{old_suffix}",
          new="x",
          "\{attribute}\{input_suffix}\{ending}",
        ),
        "x\{ending}",
      )
    }
  }
}

///|
test "attribute trailing lexical whitespace includes Unicode" {
  for attribute in ["#flag", "#coverage.skip", "#deprecated(\"reason\")"] {
    for
      suffix in [
        "\t", "\u000B", "\u000C", " ", "\u00A0", "\u1680", "\u2000", "\u2001", "\u2002",
        "\u2003", "\u2004", "\u2005", "\u2006", "\u2007", "\u2008", "\u2009", "\u200A",
        "\u2028", "\u2029", "\u202F", "\u205F", "\u3000", "\uFEFF", " \t\u00A0\u2003\u2028\u2029\u3000\uFEFF\u000B\u000C",
      ] {
      for
        (old_suffix, input_suffix) in [
          (suffix, ""),
          ("", suffix),
          (suffix.repeat(2), suffix),
        ] {
        assert_eq(
          @lexical_edit.lexical_edit(
            old="\{attribute}\{old_suffix}",
            new="x",
            "  \{attribute}\{input_suffix}\nfn f {}",
          ),
          "  x\nfn f {}",
        )
      }
    }
  }
}

///|
test "attribute replacement preserves surrounding text and supports deletion" {
  assert_eq(
    @lexical_edit.lexical_edit(
      old="#deprecated(\"reason\")",
      new="",
      "// before\n  #deprecated(\"reason\") \t\u3000\n#flag\n",
    ),
    "// before\n  \n#flag\n",
  )
  assert_eq(
    @lexical_edit.lexical_edit(
      old="#flag",
      new="#replacement  ",
      "  #flag   \n  #flag\t\n",
    ),
    "  #replacement  \n  #flag\t\n",
  )
  assert_eq(
    @lexical_edit.lexical_edit(
      old="let x = 1\n#flag",
      new="x",
      "let x = 1\n#flag \t\nfn f {}",
    ),
    "x\nfn f {}",
  )
  assert_eq(
    @lexical_edit.lexical_edit(
      old="#flag\nfn f {}",
      new="x",
      "#flag \t\nfn f {}\n",
    ),
    "x\n",
  )
}

///|
test "attribute internal whitespace and non-whitespace suffixes remain significant" {
  for
    (old, input) in [
      ("#deprecated(\"reason\")", "#deprecated( \"reason\" )  "),
      ("#deprecated(\"reason\")", "#deprecated(\"reason \")  "),
      ("#flag", "#flag\u0085  "),
      ("#flag", "#flag\u200B  "),
      ("#flag", "#flag // comment"),
      ("\"reason\"", "\"reason \""),
      ("#|reason", "#|reason "),
    ] {
    assert_true(
      edit_error(old~, new="x", input) is @lexical_edit.LEditError::NotFound,
    )
  }
}

///|
test "attribute normalization preserves Unicode StringView offsets" {
  let old = "prefix #deprecated(\"中文😀\")\u00A0 suffix"
  let input = "prefix // 😀中文\n  #deprecated(\"中文😀\")\t\u3000\r\nfn f {} suffix"
  let replacement = "[替换😀]"
  assert_eq(
    @lexical_edit.lexical_edit(
      old=old[7:old.length() - 7],
      new=replacement[1:5],
      input[7:input.length() - 7],
    ),
    "// 😀中文\n  替换😀\r\nfn f {}",
  )
}

///|
test "attribute matching falls back through normalized repeated prefixes" {
  assert_eq(
    @lexical_edit.lexical_edit(
      old="#a \n#a\t\n#b ",
      new="x",
      "#a\t\n#a \n#a\u3000\n#b\t\n",
    ),
    "#a\t\nx\n",
  )
}

///|
test "lexical errors use the first diagnostic and old takes precedence" {
  let old_error = edit_error(old="a ` `", new="x", "`")
  assert_true(
    old_error
    is @lexical_edit.LEditError::OldLexError(
      offset=2,
      message="unrecognized character u32: `"
    ),
  )
  for input in ["a ` `", "b ` `"] {
    let result = edit_error(old="a", new="x", input)
    assert_true(
      result
      is @lexical_edit.LEditError::InputLexError(
        offset=2,
        message="unrecognized character u32: `"
      ),
    )
  }
  assert_true(
    edit_error(old="\"unfinished", new="x", "a")
    is @lexical_edit.LEditError::OldLexError(..),
  )
  assert_true(
    edit_error(old="a", new="x", "a \"unfinished")
    is @lexical_edit.LEditError::InputLexError(..),
  )
}

///|
test "Unicode and nonzero StringViews use relative UTF-16 offsets" {
  let old = "prefix \"中文😀\" + a suffix"
  let input = "prefix // 😀中文\n \"中文😀\"  + a // 尾部 suffix"
  let replacement = "[替换😀]"
  assert_eq(
    @lexical_edit.lexical_edit(
      old=old[7:17],
      new=replacement[1:5],
      input[7:input.length() - 7],
    ),
    "// 😀中文\n 替换😀 // 尾部",
  )
  let invalid = "prefix \"😀\" ` ` suffix"
  let source = invalid[7:13]
  assert_true(
    edit_error(old=source, new="x", "a")
    is @lexical_edit.LEditError::OldLexError(
      offset=5,
      message="unrecognized character u32: `"
    ),
  )
  assert_true(
    edit_error(old="a", new="x", source)
    is @lexical_edit.LEditError::InputLexError(
      offset=5,
      message="unrecognized character u32: `"
    ),
  )
}

///|
test "dot compound tokens include their leading dot in the replacement" {
  for token in [".field", ".Type", ".0", ".("] {
    assert_eq(
      @lexical_edit.lexical_edit(old=token, new=".other", "obj\{token} tail"),
      "obj.other tail",
    )
    let wrapped = "__\{token}__"
    assert_eq(
      @lexical_edit.lexical_edit(
        old=token,
        new="x",
        wrapped[2:wrapped.length() - 2],
      ),
      "x",
    )
  }
}

///|
test "KMP falls back through repeated prefixes" {
  assert_eq(
    @lexical_edit.lexical_edit(old="a b a b a c", new="x", "a b a b a b a c"),
    "a b x",
  )
}

///|
test "large repeated prefix succeeds and fails" {
  let input = "a ".repeat(16000)
  let old = "a ".repeat(8000) + "b"
  assert_eq(
    @lexical_edit.lexical_edit(old~, new="x", input + "b"),
    "a ".repeat(8000) + "x",
  )
  assert_true(
    edit_error(old~, new="x", input) is @lexical_edit.LEditError::NotFound,
  )
}

///|
fn binary_tokens(length : Int, bits : Int) -> Array[String] {
  Array::makei(length, i => if ((bits >> i) & 1) == 0 { "a" } else { "b" })
}

///|
fn naive_first_match(input : Array[String], pattern : Array[String]) -> Int? {
  for start in 0..<(input.length() - pattern.length() + 1) {
    let matches = for offset in 0..<pattern.length() {
      if input[start + offset] != pattern[offset] {
        break false
      }
    } nobreak {
      true
    }
    if matches {
      return Some(start)
    }
  }
  None
}

///|
test "short binary sequences agree with naive first match" {
  for input_length in 0..<=7 {
    for input_bits in 0..<(1 << input_length) {
      let tokens = binary_tokens(input_length, input_bits)
      let input = tokens.join(" ")
      for pattern_length in 1..<=5 {
        for pattern_bits in 0..<(1 << pattern_length) {
          let pattern = binary_tokens(pattern_length, pattern_bits)
          let old = pattern.join(" ")
          match naive_first_match(tokens, pattern) {
            None =>
              assert_true(
                edit_error(old~, new="x", input)
                is @lexical_edit.LEditError::NotFound,
              )
            Some(start) => {
              let expected = tokens[:start].to_owned()
              expected.push("x")
              for token in tokens[start + pattern_length:] {
                expected.push(token)
              }
              assert_eq(
                @lexical_edit.lexical_edit(old~, new="x", input),
                expected.join(" "),
              )
            }
          }
        }
      }
    }
  }
}
