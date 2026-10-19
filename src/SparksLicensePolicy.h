#ifndef SPARKS_LICENSE_POLICY_H
#define SPARKS_LICENSE_POLICY_H
#include <math.h>
// Only an explicitly verified ok response grants access. All times are seconds.
static inline int SpLicenseAllowsSend(int verifiedOK, double verifiedUptime,
    double uptime, double serverNow, double expires, double grace) {
    double elapsed = uptime - verifiedUptime;
    return verifiedOK && isfinite(verifiedUptime) && isfinite(uptime) &&
        isfinite(serverNow) && isfinite(expires) && isfinite(grace) &&
        verifiedUptime > 0 && serverNow > 0 && expires >= 0 && grace >= 0 &&
        elapsed >= 0 && elapsed <= grace &&
        (expires == 0 || serverNow + elapsed < expires);
}
#endif
