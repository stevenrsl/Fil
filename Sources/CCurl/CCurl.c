#include "CCurl.h"

CURLcode fil_curl_global_init(void) {
    return curl_global_init(CURL_GLOBAL_ALL);
}

CURLcode fil_curl_set_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode fil_curl_set_offset(CURL *handle, CURLoption option, curl_off_t value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode fil_curl_set_string(CURL *handle, CURLoption option, const char *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode fil_curl_set_pointer(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode fil_curl_set_list(CURL *handle, CURLoption option, struct curl_slist *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode fil_curl_set_data_callback(CURL *handle, CURLoption option, fil_curl_data_callback callback) {
    return curl_easy_setopt(handle, option, callback);
}

CURLcode fil_curl_set_progress_callback(CURL *handle, fil_curl_progress_callback callback) {
    return curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, callback);
}

CURLcode fil_curl_get_string(CURL *handle, CURLINFO info, const char **value) {
    return curl_easy_getinfo(handle, info, value);
}

CURLcode fil_curl_get_long(CURL *handle, CURLINFO info, long *value) {
    return curl_easy_getinfo(handle, info, value);
}

CURLcode fil_curl_get_offset(CURL *handle, CURLINFO info, curl_off_t *value) {
    return curl_easy_getinfo(handle, info, value);
}
