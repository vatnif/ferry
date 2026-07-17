#ifndef FERRY_CFTP_H
#define FERRY_CFTP_H

// Ferry's thin C shim over the system libcurl (macOS `/usr/lib/libcurl`, curl
// license — docs/LICENSING.md, ADR-003/ADR-019). Its only job is to expose
// libcurl's *variadic* entry points — `curl_easy_setopt` and
// `curl_easy_getinfo` — as concrete, non-variadic functions, because Swift
// cannot call C variadic functions. Everything else in libcurl (init, perform,
// cleanup, slist, strerror) is a normal function Swift imports directly.

#include <curl/curl.h>

// Matches curl's write/read/header callback signature exactly, so a Swift
// `@convention(c)` function can be handed straight through.
typedef size_t (*ferry_io_cb)(char *buffer, size_t size, size_t nitems, void *userdata);

CURLcode ferry_setopt_long(CURL *handle, CURLoption option, long value);
CURLcode ferry_setopt_string(CURL *handle, CURLoption option, const char *value);
CURLcode ferry_setopt_off(CURL *handle, CURLoption option, curl_off_t value);
CURLcode ferry_setopt_slist(CURL *handle, CURLoption option, struct curl_slist *value);

// Each sets both the FUNCTION and its DATA pointer in one call.
CURLcode ferry_set_write_cb(CURL *handle, ferry_io_cb cb, void *userdata);
CURLcode ferry_set_read_cb(CURL *handle, ferry_io_cb cb, void *userdata);
CURLcode ferry_set_header_cb(CURL *handle, ferry_io_cb cb, void *userdata);

CURLcode ferry_set_errorbuffer(CURL *handle, char *buffer);

CURLcode ferry_getinfo_long(CURL *handle, CURLINFO info, long *out);
CURLcode ferry_getinfo_off(CURL *handle, CURLINFO info, curl_off_t *out);

// A handful of libcurl values that live behind C macros/enums, surfaced as
// functions so Swift never has to depend on macro importing.
void ferry_global_init(void);          // curl_global_init(CURL_GLOBAL_DEFAULT)
long ferry_error_size(void);           // CURL_ERROR_SIZE
long ferry_usessl_all(void);           // CURLUSESSL_ALL (explicit AUTH TLS)
size_t ferry_readfunc_abort(void);     // CURL_READFUNC_ABORT

#endif /* FERRY_CFTP_H */
