#include "CFTP.h"

CURLcode ferry_setopt_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode ferry_setopt_string(CURL *handle, CURLoption option, const char *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode ferry_setopt_off(CURL *handle, CURLoption option, curl_off_t value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode ferry_setopt_slist(CURL *handle, CURLoption option, struct curl_slist *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode ferry_set_write_cb(CURL *handle, ferry_io_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(handle, CURLOPT_WRITEDATA, userdata);
}

CURLcode ferry_set_read_cb(CURL *handle, ferry_io_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(handle, CURLOPT_READFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(handle, CURLOPT_READDATA, userdata);
}

CURLcode ferry_set_header_cb(CURL *handle, ferry_io_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(handle, CURLOPT_HEADERDATA, userdata);
}

CURLcode ferry_set_errorbuffer(CURL *handle, char *buffer) {
    return curl_easy_setopt(handle, CURLOPT_ERRORBUFFER, buffer);
}

CURLcode ferry_getinfo_long(CURL *handle, CURLINFO info, long *out) {
    return curl_easy_getinfo(handle, info, out);
}

CURLcode ferry_getinfo_off(CURL *handle, CURLINFO info, curl_off_t *out) {
    return curl_easy_getinfo(handle, info, out);
}

CURLcode ferry_getinfo_certinfo(CURL *handle, struct curl_certinfo **out) {
    return curl_easy_getinfo(handle, CURLINFO_CERTINFO, out);
}

CURLcode ferry_set_prereq_cb(CURL *handle, ferry_prereq_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(handle, CURLOPT_PREREQFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(handle, CURLOPT_PREREQDATA, userdata);
}

void ferry_global_init(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

long ferry_error_size(void) {
    return CURL_ERROR_SIZE;
}

long ferry_usessl_all(void) {
    return CURLUSESSL_ALL;
}

size_t ferry_readfunc_abort(void) {
    return CURL_READFUNC_ABORT;
}

int ferry_prereqfunc_ok(void) {
    return CURL_PREREQFUNC_OK;
}

int ferry_prereqfunc_abort(void) {
    return CURL_PREREQFUNC_ABORT;
}
