#include <regex.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stddef.h>

struct hty_regex {
    regex_t inner;
    int status;
};

struct hty_regex* hty_regex_compile(const char* pattern) {
    struct hty_regex* re = malloc(sizeof(struct hty_regex));
    if (!re) return NULL;
    // Note: we intentionally do *not* pass REG_NOSUB — callers want the
    // match start offset (see `hty_regex_find`). The existence-only
    // `hty_regex_match` just discards the match object.
    re->status = regcomp(&re->inner, pattern, REG_EXTENDED | REG_NEWLINE);
    return re;
}

bool hty_regex_is_valid(const struct hty_regex* re) {
    return re != NULL && re->status == 0;
}

bool hty_regex_match(const struct hty_regex* re, const char* haystack) {
    if (!re || re->status != 0) return false;
    regmatch_t m;
    return regexec(&re->inner, haystack, 1, &m, 0) == 0;
}

/// Return the byte offset of the first regex match in `haystack`, or -1
/// when the pattern doesn't match. Equivalent to `hty_regex_match` plus
/// the match position in a single regexec call.
long hty_regex_find(const struct hty_regex* re, const char* haystack) {
    if (!re || re->status != 0) return -1;
    regmatch_t m;
    if (regexec(&re->inner, haystack, 1, &m, 0) != 0) return -1;
    return (long)m.rm_so;
}

void hty_regex_free(struct hty_regex* re) {
    if (re) {
        if (re->status == 0) regfree(&re->inner);
        free(re);
    }
}
