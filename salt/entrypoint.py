#!/usr/bin/env python3
"""Render Salt's config from templates + environment, then exec Salt.

Salt reads plain YAML: it does not expand environment variables, and it
does not render Jinja in /etc/salt. So device credentials, the salt-api
shared secret, the NetBox token and the Elasticsearch password all used to
sit in files committed to git.

This renders /etc/salt/templates/** into /etc/salt/** at container start,
substituting ${VAR} from the environment, and refuses to start if any
referenced variable is missing -- a Salt master that comes up with an
empty password is worse than one that does not come up at all.

The rendered files land in the container's own filesystem at 0600, not in
a bind mount, so a secret never reaches the repo working tree.
"""

import os
import pathlib
import re
import shutil
import sys

TEMPLATES = pathlib.Path("/etc/salt/templates")
TARGET = pathlib.Path("/etc/salt")
VAR = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")


def render(text, origin):
    missing = sorted({
        name for name in VAR.findall(text) if os.environ.get(name) is None
    })
    if missing:
        sys.exit(
            f"salt-entrypoint: {origin} needs these environment variables, "
            f"which are unset: {', '.join(missing)}\n"
            f"  Did you run ./scripts/gen-secrets.sh and keep .env next to "
            f"docker-compose.yml?"
        )
    return VAR.sub(lambda m: os.environ[m.group(1)], text)


def main():
    if TEMPLATES.exists():
        for src in sorted(TEMPLATES.rglob("*")):
            if src.is_dir():
                continue
            rel = src.relative_to(TEMPLATES)
            dst = TARGET / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(render(src.read_text(), rel.as_posix()))
            dst.chmod(0o600)
            print(f"salt-entrypoint: rendered {rel}", flush=True)
    else:
        print("salt-entrypoint: no templates mounted, using image defaults",
              flush=True)

    argv = sys.argv[1:] or ["salt-master", "-l", "info"]
    binary = shutil.which(argv[0]) or argv[0]
    os.execv(binary, argv)


if __name__ == "__main__":
    main()
