# Compatibility fix for running salt-proxy as a container's PID 1 under
# Salt 3008 + saltext.napalm 0.2.0 on Python 3.12.
#
# saltext.napalm.utils.napalm.is_proxy(opts) gates on
# salt.utils.platform.is_proxy(), which in turn evaluates
#   "proxy" in __main__.__file__ or any(a.startswith("--proxyid") for a in argv)
# left-to-right — and in this environment __main__ has no __file__ at the
# point some loader contexts call it, so the left operand raises
# AttributeError and the whole check silently returns False, even though
# this genuinely is a proxy minion with proxytype: napalm in its config.
# Confirmed via direct instrumentation: opts['proxy']['proxytype'] is
# correctly 'napalm' at every call site; only the platform-level probe is
# unreliable here. Since this image only ever runs as a proxy minion, we
# replace the check with the one fact that actually matters: what's in
# the minion's own opts.
import sys


def _patch():
    import saltext.napalm.utils.napalm as nu

    def is_proxy(opts):
        return opts.get("proxy", {}).get("proxytype") == "napalm"

    nu.is_proxy = is_proxy


try:
    _patch()
except Exception:
    pass
