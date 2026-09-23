"""Make NetBox's API token match .env, and delete every token that does not.

Piped into `manage.py shell` by scripts/seed-netbox.sh.

NetBox applies SUPERUSER_API_TOKEN only when it creates the superuser on
first boot. On an existing database the variable is ignored, exactly like
Postgres and POSTGRES_PASSWORD -- so rotating the token in .env silently
breaks the config_drift beacon and sync_from_netbox, and the symptom is a
403 from a beacon nobody is watching.

The second half matters as much as the first. This repo shipped with the
well-known demo token `0123456789abcdef...` baked into its source for
weeks. Generating a new one does not revoke the old one: it stays in the
database, valid, granting write access to the source of truth that drives
config pushes to routers. Anything not named in .env is deleted here.
"""
import os

from django.contrib.auth import get_user_model
from users.models import Token

wanted = os.environ["NETBOX_API_TOKEN"]
username = os.environ.get("NETBOX_SUPERUSER_NAME", "admin")

User = get_user_model()
user, _ = User.objects.get_or_create(
    username=username, defaults={"is_superuser": True, "is_staff": True})

_, created = Token.objects.update_or_create(
    key=wanted,
    defaults={"user": user, "write_enabled": True,
              "description": "selfheal-lab (.env)"})
print(f"netbox-token: {'created' if created else 'updated'} for {username}")

stale = Token.objects.exclude(key=wanted)
for token in stale:
    print(f"netbox-token: revoking stale token ...{token.key[-6:]} "
          f"({token.description or 'no description'})")
count = stale.count()
stale.delete()
print(f"netbox-token: {count} stale token(s) revoked, "
      f"{Token.objects.count()} remaining")
