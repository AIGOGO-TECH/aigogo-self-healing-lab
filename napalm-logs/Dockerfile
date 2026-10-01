# napalm-logs pinned to Python 3.11 on purpose.
#
# napalm-logs 0.11.0 is the current release and it is from November 2022. Its
# __init__ imports pkg_resources, which setuptools stopped shipping by default
# from Python 3.12 -- so on 3.12 the library installs cleanly, imports, and
# then the CLI dies with ModuleNotFoundError: No module named 'pkg_resources'.
# An install that succeeds and a binary that does not run is the worst
# combination to debug, so the version is pinned here where it can be read.
#
# Everything else in this lab runs 3.12. This one container does not, and that
# is the cost of consuming a package with no release in four years.
FROM python:3.11-slim

RUN pip install --no-cache-dir "napalm-logs==0.11.0" \
 && rm -rf /root/.cache

# Both processes that speak napalm-logs run from this image: the daemon
# itself, and the bridge that consumes its ZeroMQ publisher. The bridge needs
# napalm_logs.utils.unserialize to decode the wire format, so it cannot live
# in the collector image with the others.
WORKDIR /srv

CMD ["napalm-logs", "--help"]
