#include "PinnedHTTP.h"
#include <pthread.h>

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static CURLcode init_result;

static void initialize_curl(void) {
    init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

struct transfer_callbacks {
    void *context;
    mbh_http_write write_body;
    mbh_http_write write_header;
    mbh_http_cancelled cancelled;
};

static size_t body_cb(char *data, size_t size, size_t count, void *user) {
    struct transfer_callbacks *transfer = user;
    return transfer->write_body(data, size * count, transfer->context);
}

static size_t header_cb(char *data, size_t size, size_t count, void *user) {
    struct transfer_callbacks *transfer = user;
    return transfer->write_header(data, size * count, transfer->context);
}

static int progress_cb(void *user, curl_off_t total_in, curl_off_t bytes_in,
                       curl_off_t total_out, curl_off_t bytes_out) {
    struct transfer_callbacks *transfer = user;
    return transfer->cancelled(transfer->context);
}

CURLcode mbh_pinned_http(
    const char *url, const char *method, const char *connect_to,
    struct curl_slist *headers, const void *body, size_t body_size,
    long timeout_ms, void *context, mbh_http_write write_body,
    mbh_http_write write_header, mbh_http_cancelled cancelled, long *status
) {
    pthread_once(&curl_once, initialize_curl);
    if (init_result != CURLE_OK) return init_result;

    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    struct curl_slist *pin = curl_slist_append(NULL, connect_to);
    if (!pin) {
        curl_easy_cleanup(curl);
        return CURLE_OUT_OF_MEMORY;
    }
    struct transfer_callbacks transfer = {context, write_body, write_header, cancelled};
    CURLcode result;

    // Fail closed if any option fails, especially the address pin or proxy disable.
#define SET(option, value) do { \
    result = curl_easy_setopt(curl, option, value); \
    if (result != CURLE_OK) goto cleanup; \
} while (0)

    SET(CURLOPT_URL, url);
    SET(CURLOPT_CUSTOMREQUEST, method);
    SET(CURLOPT_CONNECT_TO, pin);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    // PROTOCOLS_STR is newer than the libcurl shipped on the oldest macOS we support.
    SET(CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_TIMEOUT_MS, timeout_ms);
    SET(CURLOPT_CONNECTTIMEOUT_MS, timeout_ms < 4000 ? timeout_ms : 4000L);
    SET(CURLOPT_HTTPHEADER, headers);
    SET(CURLOPT_ACCEPT_ENCODING, "");
    SET(CURLOPT_WRITEFUNCTION, body_cb);
    SET(CURLOPT_WRITEDATA, &transfer);
    SET(CURLOPT_HEADERFUNCTION, header_cb);
    SET(CURLOPT_HEADERDATA, &transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, progress_cb);
    SET(CURLOPT_XFERINFODATA, &transfer);
    if (body) {
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_size);
        SET(CURLOPT_POSTFIELDS, body);
    }

    result = cancelled(context) ? CURLE_ABORTED_BY_CALLBACK : curl_easy_perform(curl);
    if (result == CURLE_OK) result = curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status);

cleanup:
    curl_easy_cleanup(curl);
    curl_slist_free_all(pin);
    return result;
#undef SET
}
