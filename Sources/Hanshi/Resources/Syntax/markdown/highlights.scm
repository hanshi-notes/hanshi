;From nvim-treesitter/nvim-treesitter
(atx_heading (inline) @text.title)
(setext_heading (paragraph) @text.title)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

[
  (link_title)
  (indented_code_block)
  (fenced_code_block)
] @text.literal

[
  (fenced_code_block_delimiter)
] @punctuation.delimiter

(code_fence_content) @none

[
  (link_destination)
] @text.uri

[
  (link_label)
] @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation.special

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

[
  (backslash_escape)
] @string.escape

; Modified for Hanshi: Markdown palette roles, retaining the broad captures above.
(atx_heading (atx_h1_marker) (inline) @text.title.1)
(atx_heading (atx_h2_marker) (inline) @text.title.2)
(atx_heading (atx_h3_marker) (inline) @text.title.3)
(atx_heading (atx_h4_marker) (inline) @text.title.4)
(atx_heading (atx_h5_marker) (inline) @text.title.5)
(atx_heading (atx_h6_marker) (inline) @text.title.6)
(setext_heading (paragraph) @text.title.1 (setext_h1_underline))
(setext_heading (paragraph) @text.title.2 (setext_h2_underline))
[(list_marker_plus) (list_marker_minus) (list_marker_star)] @text.list.bullet
[(list_marker_dot) (list_marker_parenthesis)] @text.list.number
(thematic_break) @text.hrule
[(block_continuation) (block_quote_marker)] @text.quote
(indented_code_block) @text.literal.verbatim
