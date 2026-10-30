///|
/// Errors raised by `lexical_edit` when validating the pattern or input, or finding a match.
///
/// Validation proceeds in this order: check `old` for lexical errors, check that
/// `old` contains meaningful tokens, check the entire `input` for lexical errors,
/// then search for a match. Even if the beginning of the input matches, a later
/// lexical error still raises `InputLexError`; no partial replacement is returned.
///
/// Both lexical errors preserve the first diagnostic returned by the lexer.
/// `offset` is a zero-based UTF-16 code unit offset from the start of the relevant
/// `StringView`, not a UTF-8 byte count, Unicode character count, or line/column
/// position. For a slice, the offset is relative to the slice rather than the
/// entire underlying string. For example, `😀` occupies two UTF-16 code units.
/// `message` is the lexer's original diagnostic text.
///
/// ```mbt check
/// test "handle a missing token sequence" {
///   try @lexical_edit.lexical_edit(old="foo", new="bar", "foobar") catch {
///     @lexical_edit.LEditError::NotFound => ()
///     _ => fail("expected NotFound")
///   } noraise {
///     _ => fail("expected NotFound")
///   }
/// }
/// ```
pub suberror LEditError {
  /// `old` contains no meaningful tokens after ignoring whitespace, line breaks,
  /// comments, and automatic semicolons. An empty string or a pattern containing
  /// only comments raises this error, and `input` is not validated further.
  EmptyOld
  /// `old` contains a lexical error. This error takes precedence even if `input`
  /// also contains lexical errors. `offset` is the UTF-16 code unit offset of the
  /// diagnostic's start relative to `old`; `message` is the original text of the
  /// first diagnostic returned by the lexer.
  OldLexError(offset~ : Int32, message~ : String)
  /// `old` is lexically valid and nonempty, but the entire `input` contains a
  /// lexical error. `offset` is the UTF-16 code unit offset of the diagnostic's
  /// start relative to `input`; `message` is the original text of the first
  /// diagnostic returned by the lexer. Errors after the match also trigger this case.
  InputLexError(offset~ : Int32, message~ : String)
  /// `old` is lexically valid and nonempty, and `input` is lexically valid, but no
  /// contiguous token sequence matches. This also applies to empty input, input
  /// containing only comments, or input with fewer meaningful tokens than the pattern.
  NotFound
}

///|
priv struct EditToken {
  kind : @tokens.TokenKind
  text : StringView
  start : Int32
  end : Int32
}

///|
fn same_edit_token(left : EditToken, right : EditToken) -> Bool {
  left.kind == right.kind && left.text == right.text
}

///|
fn token_prefix_table(pattern : Array[EditToken]) -> Array[Int32] {
  let prefix = Array::make(pattern.length(), 0)
  let mut matched = 0
  for i in 1..<pattern.length() {
    // Reuse the longest remaining border after a mismatch.
    while matched > 0 && !same_edit_token(pattern[i], pattern[matched]) {
      matched = prefix[matched - 1]
    }
    if same_edit_token(pattern[i], pattern[matched]) {
      matched += 1
    }
    prefix[i] = matched
  }
  prefix
}

///|
// Matches RE_UNICODE_SPACES1 and RE_LINE_BREAK in moonbitlang/lexer 0.3.16.
const ATTRIBUTE_TRAILING_WHITESPACE : String = "\t\n\u000B\u000C\r \u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF"

///|
fn edit_tokens(
  source : StringView,
  is_old~ : Bool,
) -> Array[EditToken] raise LEditError {
  let result = @lexer.tokens_from_string_with_utf16_location(
    comment=false,
    source,
  )
  if result.errors is [(start, _, error), ..] {
    let message = Show::to_string(error)
    if is_old {
      raise OldLexError(offset=start.cnum, message~)
    } else {
      raise InputLexError(offset=start.cnum, message~)
    }
  }
  let tokens = []
  for (token, start, end) in result.tokens {
    match token {
      NEWLINE | EOF | SEMI(false) => ()
      _ => {
        // These three compound tokens omit the leading dot in lexer locations.
        let start = match token {
          DOT_LIDENT(_) | DOT_UIDENT(_) | DOT_INT(_) => start.cnum - 1
          _ => start.cnum
        }
        let end = end.cnum
        let text = source[start:end]
        let text = match token {
          // Normalize comparison text while retaining the original replacement span.
          ATTRIBUTE(_) => text.trim_end(chars=ATTRIBUTE_TRAILING_WHITESPACE)
          _ => text
        }
        tokens.push({ kind: token.kind(), text, start, end, })
      }
    }
  }
  tokens
}

///|
/// Replaces the first contiguous MoonBit token sequence in `input` that matches
/// `old`, scanning from left to right, with `new`.
///
/// # Parameters and return value
///
/// - `old`: A required named argument specifying the code fragment to find.
///   Leading and trailing whitespace and comments do not affect match locations.
///   At least one token must remain after ignored items are removed. This is not
///   a regular expression, and wildcards are not supported.
/// - `new`: A required named argument specifying the text to insert verbatim.
///   An empty string deletes the matched range. No lexical or syntactic validation
///   is performed, and indentation, line breaks, and escapes are not adjusted.
///   No separators are added.
/// - `input`: A positional argument specifying the source text to edit, either
///   complete source code or a string slice.
///
/// Returns a `String` consisting of the original text before the matched range,
/// `new`, and the original text after the matched range. Only the supplied view
/// is processed; underlying string content outside the view is not included.
/// The arguments are not modified. Each call replaces at most one occurrence,
/// leaving other matches unchanged. If no match is found, `NotFound` is raised
/// instead of returning the original text as a successful result.
///
/// # Matching rules
///
/// `old` and `input` are tokenized using ordinary MoonBit lexical rules. Code
/// fragments need not form complete syntax. Comparisons ignore whitespace, line
/// breaks, comments, and automatically inserted semicolons between tokens.
/// Explicit `;` tokens must match: for example, `a b` does not match `a;b`.
///
/// Each token's kind and original text must match exactly, except that trailing
/// lexer-recognized whitespace in attribute tokens is ignored, including Unicode
/// whitespace. Matching is case-sensitive, and literal values are not normalized:
/// `foo` does not match `foobar`, `1` does not match `01`, and `1.0` does not match
/// `1.00`.
/// Individual tokens such as strings, interpolated strings, and attributes are
/// compared as a whole, with no recursive search inside them. Their internal
/// whitespace must also match. Compound tokens such as `.field` include the
/// leading dot, so `field` does not match `.field`, and replacing `.field` also
/// replaces the dot.
///
/// The replacement range starts at the beginning of the first matched token and
/// ends at the end of the last matched token. Whitespace and comments inside
/// this range are removed; text outside it is preserved verbatim.
/// Attributes retain their original lexer spans, so their ignored trailing
/// whitespace is removed with the attribute. ASCII line endings (LF, CRLF, or CR)
/// after a final attribute are outside its token and are preserved.
/// The result is not tokenized again after insertion. It may contain lexical
/// errors or join adjacent tokens together. Any required spaces or other
/// separators must be supplied explicitly in `new`.
///
/// # Errors
///
/// Checks and raises `LEditError` in the following order, without using lexical
/// recovery tokens or falling back to text matching:
///
/// 1. `OldLexError`: `old` contains a lexical error.
/// 2. `EmptyOld`: `old` is lexically valid but contains no tokens to match.
/// 3. `InputLexError`: The entire `input` contains a lexical error, including
///    errors after the first match.
/// 4. `NotFound`: Validation succeeds, but no contiguous token sequence matches `old`.
///
/// Lexical errors report only the first lexer diagnostic in the relevant view.
/// Offsets count UTF-16 code units from the start of that view; see `LEditError`
/// for details.
///
/// # Examples
///
/// Match across whitespace and comments, replace only the first occurrence, and
/// preserve formatting outside the matched range:
///
/// ```mbt check
/// test "replace the first token match" {
///   let result = @lexical_edit.lexical_edit(
///     old="a + b",
///     new="sum",
///     "  a // inside\n + b  // after\n a+b",
///   )
///   assert_eq(result, "  sum  // after\n a+b")
/// }
/// ```
///
/// An empty replacement deletes the matched range without merging spaces outside it:
///
/// ```mbt check
/// test "delete tokens without trimming surrounding text" {
///   assert_eq(
///     @lexical_edit.lexical_edit(old=" + b", new="", "a + b + b"),
///     "a  + b",
///   )
/// }
/// ```
pub fn lexical_edit(
  old~ : StringView,
  new~ : StringView,
  input : StringView,
) -> String raise LEditError {
  let pattern = edit_tokens(old, is_old=true)
  guard !pattern.is_empty() else { raise EmptyOld }
  let tokens = edit_tokens(input, is_old=false)
  guard tokens.length() >= pattern.length() else { raise NotFound }
  let prefix = token_prefix_table(pattern)
  let mut matched = 0
  // KMP uses O(N + M) token comparisons and O(M) extra space.
  // Fall back within the pattern without moving the input position backward.
  for i in 0..<tokens.length() {
    while matched > 0 && !same_edit_token(tokens[i], pattern[matched]) {
      matched = prefix[matched - 1]
    }
    if same_edit_token(tokens[i], pattern[matched]) {
      matched += 1
    }
    if matched == pattern.length() {
      let first = tokens[i - pattern.length() + 1].start
      let last = tokens[i].end
      return "\{input[:first]}\{new}\{input[last:]}"
    }
  }
  raise NotFound
}
