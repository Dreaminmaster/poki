#include <Security/Security.h>
#include <stdatomic.h>
#include <stdlib.h>

static atomic_bool fail_next_delete;

void poki_test_fail_next_auto_unlock_delete(int enabled) {
    atomic_store(&fail_next_delete, enabled != 0);
}

__attribute__((constructor)) static void configure_failure(void) {
    poki_test_fail_next_auto_unlock_delete(getenv("POKI_TEST_FAIL_AUTO_UNLOCK_DELETE") != NULL);
}

static OSStatus delete_item(CFDictionaryRef query) {
    if (!query || !atomic_load(&fail_next_delete)) return SecItemDelete(query);
    CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
    CFTypeRef account = CFDictionaryGetValue(query, kSecAttrAccount);
    if (service && account && CFEqual(service, CFSTR("nz.zheha.poki")) &&
        CFEqual(account, CFSTR("device-unlock.passcode.v1")) && atomic_exchange(&fail_next_delete, 0)) {
        return errSecInteractionNotAllowed;
    }
    return SecItemDelete(query);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} keychain_delete = { (const void *)delete_item, (const void *)SecItemDelete };
