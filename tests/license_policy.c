#include <assert.h>
#include <stdio.h>
#include "../src/SparksLicensePolicy.h"
int main(void) {
    const double grace = 72 * 3600;
    assert(SpLicenseAllowsSend(1, 100, 101, 1000, 0, grace));
    assert(!SpLicenseAllowsSend(0, 100, 101, 1000, 0, grace)); // pending/blocked/expired
    assert(!SpLicenseAllowsSend(1, 0, 101, 1000, 0, grace)); // never verified
    assert(!SpLicenseAllowsSend(1, 100, 99, 1000, 0, grace)); // clock reset
    assert(SpLicenseAllowsSend(1, 100, 100 + grace, 1000, 0, grace));
    assert(!SpLicenseAllowsSend(1, 100, 101 + grace, 1000, 0, grace));
    assert(SpLicenseAllowsSend(1, 100, 109, 1000, 1010, grace));
    assert(!SpLicenseAllowsSend(1, 100, 110, 1000, 1010, grace)); // exact expiry
    assert(!SpLicenseAllowsSend(1, 100, 111, 1000, 1010, grace));
    assert(!SpLicenseAllowsSend(1, 100, 101, 1000, -1, grace));
    assert(!SpLicenseAllowsSend(1, 100, NAN, 1000, 0, grace));
    assert(!SpLicenseAllowsSend(1, 100, 101, INFINITY, 0, grace));
    puts("12 license policy cases passed");
}
