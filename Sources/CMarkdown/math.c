#include "CMarkdown.h"
#include <cmark-gfm-extension_api.h>
#include <cmark-gfm-core-extensions.h>
#include <pthread.h>
#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>

static cmark_syntax_extension *math_extension;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static const char *math_name(cmark_syntax_extension *extension, cmark_node *node) {
    return cmark_node_get_user_data(node) ? "display_math" : "math";
}

static cmark_node *match_math(cmark_syntax_extension *extension, cmark_parser *parser,
    cmark_node *parent, unsigned char character, cmark_inline_parser *inline_parser) {
    if (character != '$') return NULL;
    int start = cmark_inline_parser_get_offset(inline_parser);
    int count = cmark_inline_parser_peek_at(inline_parser, start + 1) == '$' ? 2 : 1;
    unsigned char first = cmark_inline_parser_peek_at(inline_parser, start + count);
    if (!first || (count == 1 && isspace(first))) return NULL;
    for (int end = start + count; end < start + 8192; end++) {
        unsigned char ch = cmark_inline_parser_peek_at(inline_parser, end);
        if (!ch || (count == 1 && (ch == '\n' || ch == '\r' || ch == '`' || ch == '<'))) return NULL;
        if (ch == '\\') { end++; continue; }
        if (count == 1 && ch == ']' && (cmark_inline_parser_peek_at(inline_parser, end + 1) == '(' || cmark_inline_parser_peek_at(inline_parser, end + 1) == '[')) return NULL;
        if (ch != '$') continue;
        if (count == 2 && cmark_inline_parser_peek_at(inline_parser, end + 1) != '$') continue;
        unsigned char after = cmark_inline_parser_peek_at(inline_parser, end + count);
        if (end == start + count || (count == 1 && (isspace(cmark_inline_parser_peek_at(inline_parser, end - 1)) || isdigit(after)))) return NULL;
        size_t length = (size_t)(end - start - count);
        char *latex = malloc(length + 1);
        if (!latex) return NULL;
        for (size_t i = 0; i < length; i++) latex[i] = cmark_inline_parser_peek_at(inline_parser, start + count + (int)i);
        latex[length] = 0;
        cmark_node *node = cmark_node_new(CMARK_NODE_CODE);
        cmark_node_set_literal(node, latex);
        free(latex);
        cmark_node_set_syntax_extension(node, extension);
        cmark_node_set_user_data(node, (void *)(intptr_t)(count == 2));
        cmark_inline_parser_set_offset(inline_parser, end + count);
        return node;
    }
    return NULL;
}

static void initialize(void) {
    cmark_gfm_core_extensions_ensure_registered();
    math_extension = cmark_syntax_extension_new("hanshi_math");
    cmark_syntax_extension_set_match_inline_func(math_extension, match_math);
    cmark_syntax_extension_set_get_type_string_func(math_extension, math_name);
    cmark_llist *characters = cmark_llist_append(cmark_get_default_mem_allocator(), NULL, (void *)'$');
    cmark_syntax_extension_set_special_inline_chars(math_extension, characters);
}

cmark_parser *hanshi_markdown_parser(void) {
    pthread_once(&once, initialize);
    cmark_parser *parser = cmark_parser_new(CMARK_OPT_DEFAULT | CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE);
    const char *names[] = {"table", "strikethrough", "autolink", "tasklist"};
    for (int i = 0; i < 4; i++) cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(names[i]));
    cmark_parser_attach_syntax_extension(parser, math_extension);
    return parser;
}
