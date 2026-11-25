#ifndef MBH_PINNED_HTTP_H
#define MBH_PINNED_HTTP_H

#include <curl/curl.h>

typedef size_t (*mbh_http_write)(const char *, size_t, void *);
typedef int (*mbh_http_cancelled)(void *);

CURLcode mbh_pinned_http(
    const char *url, const char *method, const char *connect_to,
    struct curl_slist *headers, const void *body, size_t body_size,
    long timeout_ms, void *context, mbh_http_write write_body,
    mbh_http_write write_header, mbh_http_cancelled cancelled, long *status
);

#endif
