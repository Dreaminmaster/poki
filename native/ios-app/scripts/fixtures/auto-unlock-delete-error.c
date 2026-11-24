#include <Security/Security.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

static atomic_bool fail_next_delete;
static atomic_bool fail_next_write;

void poki_test_fail_next_auto_unlock_delete(int enabled) {
    atomic_store(&fail_next_delete, enabled != 0);
}

void poki_test_fail_next_auto_unlock_write(int enabled) {
    atomic_store(&fail_next_write, enabled != 0);
}

__attribute__((constructor)) static void configure_failure(void) {
    poki_test_fail_next_auto_unlock_delete(getenv("POKI_TEST_FAIL_AUTO_UNLOCK_DELETE") != NULL);
    poki_test_fail_next_auto_unlock_write(getenv("POKI_TEST_FAIL_AUTO_UNLOCK_WRITE") != NULL);
}

static bool is_auto_unlock_item(CFDictionaryRef query) {
    if (!query) return false;
    CFTypeRef service = CFDictionaryGetValue(query, kSecAttrService);
    CFTypeRef account = CFDictionaryGetValue(query, kSecAttrAccount);
    return service && account && CFEqual(service, CFSTR("nz.zheha.poki")) &&
        CFEqual(account, CFSTR("device-unlock.passcode.v1"));
}

static OSStatus delete_item(CFDictionaryRef query) {
    if (is_auto_unlock_item(query) &&
        (atomic_exchange(&fail_next_delete, false) || atomic_exchange(&fail_next_write, false))) {
        return errSecInteractionNotAllowed;
    }
    return SecItemDelete(query);
}

static OSStatus update_item(CFDictionaryRef query, CFDictionaryRef attributes) {
    if (is_auto_unlock_item(query) && atomic_exchange(&fail_next_write, false)) {
        return errSecInteractionNotAllowed;
    }
    return SecItemUpdate(query, attributes);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} keychain_delete = { (const void *)delete_item, (const void *)SecItemDelete };

__attribute__((used, section("__DATA,__interpose")))
static const struct {
    const void *replacement;
    const void *original;
} keychain_update = { (const void *)update_item, (const void *)SecItemUpdate };
