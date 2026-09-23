"""
Confirmed commit, done by the device rather than by Salt.

Salt has its own `revert_in` on netconfig.managed / net.load_config, but
its confirm/cancel functions take a JID — it schedules a Salt job to undo
the change later. That is a useful safety net right up until the thing
that breaks is Salt itself, or the host it runs on, or the network path
between the master and the device. Then the scheduled revert never fires
and the bad config stays.

NAPALM's srlinux driver can arm the device's own commit-confirmed timer
instead: the router reverts on its own clock, with no help from anyone.
If the master dies one second after the push, the change still comes
back out. That is the property operators actually want, so this module
exposes it directly.

    salt srl1 netsafe.push_confirmed 'set / interface ethernet-1/9 description "x"' revert_in=60
    salt srl1 netsafe.pending
    salt srl1 netsafe.confirm
"""

import logging
import threading
import traceback

log = logging.getLogger(__name__)

# One device, one candidate, one thread at a time.
#
# The proxy-minion runs with multiprocessing: false, so every Salt job on
# this minion is a THREAD in one process, and _device() hands all of them
# the same NAPALM driver object -- deliberately, because SR Linux's
# JSON-RPC server will not tolerate a second session. That sharing extends
# to the driver's `_candidate` attribute, which is the loaded-but-not-yet
# committed configuration.
#
# Two jobs at once is not an edge case here, it is the normal case: an
# interface going down produces an iface_down fault AND a config_drift
# fault, and the reactor answers both. Interleaved, they do this:
#
#     restore_interface   load_merge_candidate()   _candidate = {...}
#     sync_from_netbox    load + commit            _candidate = None
#     restore_interface   commit_config()          -> TypeError:
#                                                     'NoneType' object is
#                                                     not subscriptable
#
# The heal fails, the audit trail correctly records change.failed, and the
# network stays broken -- intermittently, which is why this looked
# unreproducible for days.
#
# RLock rather than Lock: confirm() is reached from inside a held section
# in the states that verify an outcome.
_DEVICE_LOCK = threading.RLock()

try:
    import napalm
    HAS_NAPALM = True
except ImportError:
    HAS_NAPALM = False

__virtualname__ = "netsafe"


def __virtual__():
    if not HAS_NAPALM:
        return False, "napalm is not installed"
    return __virtualname__


def _device():
    """Return (driver, owned) for this device.

    Reuses the connection the proxy-minion already holds wherever possible.
    Opening a second session looked harmless and was not: SR Linux's JSON-RPC
    server tolerates only a small number of concurrent sessions, so as soon
    as two remediations ran against one device at the same time -- which the
    cascade from a single interface failure produces routinely, since a dead
    interface also takes BGP down -- both pushes died with

        ConnectionException: JSON-RPC request failed: timed out

    `owned` tells the caller whether it may close what it was given. Closing
    the proxy's shared connection would break every later job on that minion.
    """
    try:
        dev = __proxy__["napalm.get_device"]()
        driver = (dev or {}).get("DRIVER")
        # Present is not the same as usable. A proxy-minion answers
        # test.ping as soon as its own process is up, which can be well
        # before its device session is open -- and handing back a closed
        # driver produces "Device connection is not open; call open()
        # first" from somewhere deep in NAPALM, which reads like a bug in
        # the remediation rather than a startup race.
        if driver is not None and getattr(driver, "is_alive", None):
            try:
                if driver.is_alive().get("is_alive"):
                    return driver, False
                log.warning("proxy connection is not alive; opening our own")
            except Exception:  # noqa: BLE001
                log.warning("proxy connection did not answer; opening our own")
        elif driver is not None:
            return driver, False
    except (NameError, KeyError, TypeError, AttributeError):
        # No usable proxy connection. Falling through to our own is correct
        # here, but it is worth knowing it happened: the usual cause is a
        # proxy-minion that has answered test.ping but has not finished
        # opening its device session, which shows up as a bare
        # "TypeError: NoneType object is not subscriptable" from inside the
        # driver if it is allowed to reach that far.
        log.warning("no established proxy connection; opening our own")

    # No proxy context (running on the master, or under a plain minion):
    # fall back to a connection of our own, and close it afterwards.
    proxy_cfg = __opts__.get("proxy", {})
    driver = napalm.get_network_driver(proxy_cfg.get("driver", "srlinux"))
    own = driver(
        hostname=proxy_cfg.get("host"),
        username=proxy_cfg.get("username"),
        password=proxy_cfg.get("password"),
        optional_args=proxy_cfg.get("optional_args", {}),
    )
    own.open()
    return own, True


def push_confirmed(config, revert_in=60):
    """Load a config snippet and commit it with the DEVICE's revert timer
    armed. Returns the diff that was applied."""
    dev, owned = _device()
    try:
        with _DEVICE_LOCK:
            dev.load_merge_candidate(config=config)
            diff = dev.compare_config()
            if not (diff or "").strip():
                dev.discard_config()
                return {"result": True, "changed": False, "comment": "Already configured."}
            dev.commit_config(message="salt netsafe push", revert_in=int(revert_in))
            return {
                "result": True,
                "changed": True,
                "diff": diff,
                "revert_in": int(revert_in),
                "pending_confirm": dev.has_pending_commit(),
                "comment": (
                    f"Committed with a {revert_in}s device-side revert timer. "
                    "Call netsafe.confirm to keep it."
                ),
            }
    finally:
        if owned:
            dev.close()


def push_template(template_name, context=None, trace_id=None, actor=None,
                  state_name=None, revert_in=None, test=False, saltenv="base"):
    """Render a remediation template and push it, leaving a named commit.

    This exists rather than net.load_template because load_template has no
    way to set a commit message, and the commit message is the point: it
    carries the trace id and the actor onto the device itself.

        A:admin# info from state /system configuration checkpoint *
        ... selfheal trace=srl3-20260915T041311Z-4f2a1c actor=n8n/llama3.1
            state=restore_interface

    Anyone holding a CLI session on that router can see which automated
    decision changed it and go look the decision up, without access to
    Salt, Elasticsearch or the ticket system. When the audit store and the
    device disagree, that is a finding -- and without a marker on the
    device there is nothing to disagree with.

    Returns a dict with the diff that was applied (or would be, under
    test=True) so the caller can put it in the audit record.
    """
    context = context or {}
    rendered = __salt__["cp.get_template"](
        template_name, "", template="jinja", context=context, saltenv=saltenv
    )
    if not rendered:
        return {"result": False, "changed": False,
                "comment": f"could not render {template_name}"}
    with open(rendered, encoding="utf-8") as handle:
        config_text = handle.read()

    message = " ".join(filter(None, [
        "selfheal",
        f"trace={trace_id}" if trace_id else None,
        f"actor={actor}" if actor else None,
        f"state={state_name}" if state_name else None,
    ]))

    dev, owned = _device()
    try:
        with _DEVICE_LOCK:
            dev.load_merge_candidate(config=config_text)
            diff = (dev.compare_config() or "").strip()

            if not diff:
                dev.discard_config()
                return {"result": True, "changed": False, "diff": "",
                        "comment": "Already in the desired state."}

            if test:
                dev.discard_config()
                return {"result": None, "changed": False, "diff": diff,
                        "comment": "Would apply the diff above."}

            if revert_in:
                dev.commit_config(message=message, revert_in=int(revert_in))
            else:
                dev.commit_config(message=message)

            return {"result": True, "changed": True, "diff": diff,
                    "commit_message": message,
                    "revert_in": int(revert_in) if revert_in else None,
                    "comment": f"Committed as: {message}"}
    except Exception as err:  # noqa: BLE001 - report, never leave a candidate
        try:
            dev.discard_config()
        except Exception:  # noqa: BLE001
            pass
        # The bare "TypeError: 'NoneType' object is not subscriptable" this
        # used to return cost an afternoon: it names neither the driver call
        # that failed nor the line it failed on, and the state engine shows
        # only this comment. The traceback goes to the proxy's log, where it
        # can be read without editing this file first.
        log.error("push_template failed on %s (state=%s trace=%s):\n%s",
                  __grains__.get("id", "?"), state_name, trace_id,
                  traceback.format_exc())
        return {"result": False, "changed": False, "diff": "",
                "comment": f"{type(err).__name__}: {err} "
                           f"(traceback in the salt-proxy log)"}
    finally:
        if owned:
            dev.close()


def pending():
    """Is there an unconfirmed commit waiting to be rolled back?"""
    dev, owned = _device()
    try:
        return {"pending_confirm": dev.has_pending_commit()}
    finally:
        if owned:
            dev.close()


def confirm():
    """Keep a change that is currently under a revert timer."""
    dev, owned = _device()
    try:
        if not dev.has_pending_commit():
            return {"result": False, "comment": "Nothing pending to confirm."}
        dev.confirm_commit()
        return {"result": True, "comment": "Confirmed — the change is permanent."}
    finally:
        if owned:
            dev.close()
