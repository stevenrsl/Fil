#ifndef FIL_CCURL_H
#define FIL_CCURL_H

#include <curl/curl.h>

// `curl_easy_setopt` et `curl_easy_getinfo` sont variadiques : Swift ne peut pas les appeler.
// Ces fonctions typées sont la seule surface utilisée par Fil.

typedef size_t (*fil_curl_data_callback)(char *buffer, size_t size, size_t count, void *context);
typedef int (*fil_curl_progress_callback)(void *context, curl_off_t download_total, curl_off_t download_now, curl_off_t upload_total, curl_off_t upload_now);

CURLcode fil_curl_global_init(void);

CURLcode fil_curl_set_long(CURL *handle, CURLoption option, long value);
CURLcode fil_curl_set_offset(CURL *handle, CURLoption option, curl_off_t value);
CURLcode fil_curl_set_string(CURL *handle, CURLoption option, const char *value);
CURLcode fil_curl_set_pointer(CURL *handle, CURLoption option, void *value);
CURLcode fil_curl_set_list(CURL *handle, CURLoption option, struct curl_slist *value);
CURLcode fil_curl_set_data_callback(CURL *handle, CURLoption option, fil_curl_data_callback callback);
CURLcode fil_curl_set_progress_callback(CURL *handle, fil_curl_progress_callback callback);

CURLcode fil_curl_get_string(CURL *handle, CURLINFO info, const char **value);
CURLcode fil_curl_get_long(CURL *handle, CURLINFO info, long *value);
CURLcode fil_curl_get_offset(CURL *handle, CURLINFO info, curl_off_t *value);

#endif
