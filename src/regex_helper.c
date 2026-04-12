#include <regex.h>
#include <stdbool.h>
#include <stdlib.h>

struct hty_regex {
    regex_t inner;
    int status;
};

struct hty_regex* hty_regex_compile(const char* pattern) {
    struct hty_regex* re = malloc(sizeof(struct hty_regex));
    if (!re) return NULL;
    re->status = regcomp(&re->inner, pattern, REG_EXTENDED | REG_NOSUB | REG_NEWLINE);
    return re;
}

bool hty_regex_is_valid(const struct hty_regex* re) {
    return re != NULL && re->status == 0;
}

bool hty_regex_match(const struct hty_regex* re, const char* haystack) {
    if (!re || re->status != 0) return false;
    return regexec(&re->inner, haystack, 0, NULL, 0) == 0;
}

void hty_regex_free(struct hty_regex* re) {
    if (re) {
        if (re->status == 0) regfree(&re->inner);
        free(re);
    }
}
