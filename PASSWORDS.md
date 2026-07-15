# Password Management — SHA-256 Secrets in Kubernetes

All application passwords are managed through **GitHub Actions Secrets**, hashed with **SHA-256**, and stored as **Kubernetes Secrets**. Passwords are never stored in plaintext anywhere.

## How It Works

1. **GitHub Actions Secret** stores the plaintext password (visible only to repo admins)
   - Name: `APP_PASSWORD_<USERNAME>` (uppercase)
   - Example: `APP_PASSWORD_AMELIE = "baguette"`

2. **GitHub Actions Workflow** (`rotate-secrets.yml`) runs on every push to `main`
   - Calls `scripts/generate-app-secrets.sh`
   - Reads the GitHub Secret
   - Generates SHA-256 hash
   - Creates/updates Kubernetes Secret `app-passwords`

3. **Kubernetes Secret** stores the hash (visible via `kubectl get secrets`)
   - Format: `username:sha256_hash` (one per line)
   - Mounted in auth-service at `/run/secrets/app-passwords/passwords.txt`

4. **Auth-service** verifies login
   - Extracts username from email (e.g., `amelie@crumbandember.dev` → `amelie`)
   - Hashes incoming password with SHA-256
   - Compares against stored hash
   - Falls back to database (scrypt) if not in Secret

## Managing Passwords

### Add or Change a User Password

1. Go to GitHub repository → **Settings** → **Secrets and variables** → **Actions**

2. Create or update a secret:
   - **Name:** `APP_PASSWORD_<USERNAME>` (must be uppercase)
   - **Value:** The plaintext password (min. 8 chars recommended)
   - Example:
     - `APP_PASSWORD_AMELIE` = `newbaguette123`
     - `APP_PASSWORD_TOMAS` = `croissant456`

3. On next push to `main` (or manual trigger of `rotate-secrets` workflow), the Secret is regenerated with the new hash

4. The auth-service pod reads the updated Secret on next restart or refresh

### View Current Passwords

To see which users are configured (without revealing passwords):

```bash
# List Kubernetes Secrets
kubectl -n bakery get secrets

# View the app-passwords Secret (shows base64-encoded hashes)
kubectl -n bakery get secret app-passwords -o yaml

# See which usernames are configured
kubectl -n bakery get secret app-passwords -o jsonpath='{.data.passwords\.txt}' | base64 -d
```

### Remove a User

1. Delete the GitHub secret `APP_PASSWORD_<USERNAME>`
2. On next CD run, that user will no longer be in the Secret
3. To block login immediately: edit the Secret directly (advanced):
   ```bash
   kubectl -n bakery edit secret app-passwords
   ```

## Technical Details

### Hash Algorithm

- **SHA-256** (64 hex characters)
- **No salt** — each password is hashed once; the hash is deterministic
- Incoming passwords are hashed in the same way for comparison (timing-safe)

### Security Notes

- Plaintext passwords are only stored in **GitHub Secrets** (visible to repo admins)
- **Kubernetes Secrets are base64-encoded, not encrypted by default**
  - Enable encryption at rest: follow [Kubernetes encryption docs](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
  - Or use a Secret management system (Sealed Secrets, External Secrets, HashiCorp Vault)
- The hash is safe to commit to the repo (it's a public Secret manifest) — it cannot be reversed
- Auth-service logs the source (`secret` or `database`) for auditing

### Fallback (Database)

Users can also be created in the database with scrypt-hashed passwords:

```bash
# Signup endpoint
curl -X POST http://localhost:3000/api/auth/register \
  -H 'content-type: application/json' \
  -d '{
    "email": "newuser@example.com",
    "password": "securepassword123",
    "name": "New User"
  }'
```

Database-registered users are verified against their scrypt hash and do not need a GitHub Secret.

## Demo Users

Out of the box:

| Email | Password | Stored In |
|-------|----------|-----------|
| `amelie@crumbandember.dev` | `baguette` | Kubernetes Secret |
| `tomas@example.com` | `croissant` | Kubernetes Secret (optional) |

To change `amelie`'s password:
1. Go to GitHub Secrets
2. Update `APP_PASSWORD_AMELIE` to a new password
3. Push to main or manually trigger `rotate-secrets` workflow
4. Next login will use the new password

## Workflow: Rotate Secrets

The `rotate-secrets.yml` workflow runs automatically on every push to `main`:

```bash
# Manual trigger (if needed)
gh workflow run rotate-secrets.yml --ref main

# Or trigger in GitHub UI:
# Actions → Rotate platform secrets (CD) → Run workflow
```

Optionally, disable automatic runs in `.github/workflows/rotate-secrets.yml` if you prefer manual password updates.

## Troubleshooting

**Login fails with "Invalid email or password"**
- Check that the GitHub Secret name is exactly `APP_PASSWORD_<USERNAME>` (uppercase username)
- Verify the username matches the email prefix (e.g., `amelie` from `amelie@example.com`)
- Ensure the `rotate-secrets` workflow has run and the Secret exists: `kubectl -n bakery get secret app-passwords`

**Secret not updating after GitHub Secret change**
- The workflow only runs on push to `main`; if you changed the Secret in a branch, merge the PR first
- Or manually trigger: `gh workflow run rotate-secrets.yml`

**Auth-service logging "secret_load_failed"**
- The pod may not have the RBAC permissions to read the Secret
- Check the Secret exists: `kubectl -n bakery get secret app-passwords`
- Restart the auth-service pod: `kubectl -n bakery rollout restart deploy/auth-service`

## Next Steps

- Enable Kubernetes encryption at rest for all Secrets
- Rotate demo account passwords on first deployment
- Add audit logging for password changes (GitHub Actions secret update audit trail)
- Consider integrating a Secret manager (Vault, Sealed Secrets) for higher security
