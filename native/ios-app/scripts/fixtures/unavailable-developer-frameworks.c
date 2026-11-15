#include <dlfcn.h>
#include <string.h>

static void *without_developer_frameworks(const char *path, int mode) {
    if (path && strncmp(path, "/System/Developer/", strlen("/System/Developer/")) == 0) {
        return dlopen("/poki-test-fixtures/developer-framework-not-mounted", mode);
    }
    return dlopen(path, mode);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} developer_framework_loader = { (const void *)without_developer_frameworks, (const void *)dlopen };
