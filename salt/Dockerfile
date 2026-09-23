FROM python:3.12-slim

# build-essential is needed only to compile salt's C extensions (timelib et al);
# it is dropped again so the runtime image stays small.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential python3-dev \
      procps iproute2 curl jq \
 && pip install --no-cache-dir \
      "salt" \
      "napalm>=5.0" \
      "napalm-srlinux" \
      "saltext.napalm" \
      "saltext.elasticsearch" \
      "elasticsearch" \
 && apt-get purge -y build-essential python3-dev \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

COPY patches/sitecustomize.py /usr/local/lib/python3.12/site-packages/sitecustomize.py

# Renders /etc/salt/templates/** -> /etc/salt/** from the environment before
# exec'ing Salt, so no credential is committed to git. See entrypoint.py.
COPY entrypoint.py /usr/local/bin/salt-entrypoint
RUN chmod +x /usr/local/bin/salt-entrypoint

RUN mkdir -p /etc/salt /srv/salt /srv/pillar /var/log/salt

ENTRYPOINT ["/usr/local/bin/salt-entrypoint"]
CMD ["salt-master", "-l", "info"]
