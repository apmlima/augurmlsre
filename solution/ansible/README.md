# Ansible bootstrap playbook

Runs against `localhost` and replaces the manual commands from the
assignment README (steps 1 and 2), then waits until Flux reconciles the app.

## Install

```bash
brew install ansible          # or: pipx install ansible-core
```

**Collections:** none. `site.yml` uses only `ansible.builtin` modules, so
`requirements.yml` ships empty and `ansible-galaxy collection install -r
requirements.yml` is a no-op. If you later swap the CLI calls for
`kubernetes.core` modules, add the collection to `requirements.yml` and run the
install command above.

## What it does, in order

| # | Step | Replaces (README) |
|---|------|-------------------|
| 0 | preflight: minikube/docker/kubectl present, Docker daemon up | — |
| 1 | (optional, on by default) install the flux-operator CLI into `~/.local/bin` | manual prereq install |
| 2 | start minikube (only if not already running) | `minikube start` |
| 3 | assert kubectl context == the minikube profile (mutation safety) | — |
| 4 | build `griffin:0.1.0` if the image is missing locally | `docker build -t griffin:0.1.0 src` |
| 5 | `minikube image load griffin:0.1.0` (only if not loaded already) | step 2 "make available to minikube" |
| 6 | ensure `flux-system` namespace | — |
| 7 | create git basic-auth secret from `GITHUB_USER`/`GITHUB_TOKEN` (stdin, `no_log`) | `flux-operator create secret basic-auth ...` |
| 8 | create `sops-age` secret from `~/.config/sops/age/keys.txt` (`no_log`) | README step 4 (flux side) |
| 9 | `flux-operator install -f ../clusters/minikube/flux-instance.yaml` (only if operator absent) | `flux-operator install ...` |
| 10 | `kubectl apply -f flux-instance.yaml` (idempotent drift healing) | — |
| 11 | wait: GitRepository Ready → infrastructure Ready → apps Ready → griffin rollout | "Verify flux is reconciling correctly" |

Secrets are created **before** the operator install on purpose: the install
waits for the `FluxInstance` to become Ready, and the sync cannot progress
without the basic-auth secret, so the naive README ordering is what "hangs".

## Run

```bash
export GITHUB_USER=your-github-user
export GITHUB_TOKEN=ghp_xxx        # classic PAT with repo scope

cd solution/ansible
ansible-playbook site.yml
```

- Run it twice: the second run should show `changed=0` (see the idempotency
  table below).
- On subsequent runs the credentials are not needed unless the git secret was
  deleted; the playbook only reads them when it has to create the secret.
- Nothing secret is committed anywhere: the PAT is read from the environment,
  piped via stdin to `--password-stdin` (never in argv), the age key lives at
  `~/.config/sops/age/keys.txt` outside the repo, and every task that touches
  either one has `no_log: true`.

## Idempotency design

The rule used throughout: **probe mutable state first; only mutate when the
probe says it is missing**. `Probe → when` pairs per task:

| Task | Probe | Mutates when |
|------|-------|--------------|
| start minikube | `minikube status -p minikube -o json` | profile Host state isn't `Running` |
| build image | `docker image inspect griffin:0.1.0` | image absent locally |
| load image | `minikube image ls \| grep -F griffin:0.1.0` | image absent in node |
| create namespace | — (`kubectl create ns` + `AlreadyExists` tolerated) | namespace actually created |
| basic-auth secret | `kubectl get secret flux-system` | secret missing |
| sops-age secret | `kubectl get secret sops-age` | secret missing |
| flux-operator install | `kubectl get deployment flux-operator` | deployment missing |
| apply FluxInstance | — (kubectl apply is idempotent; only `configured`/`created` count) | spec differs |
| wait/rollout tasks | — | never (`changed_when: false`) |

Known trade-offs (documented, deliberate):

- The secrets tasks do not update existing secrets if rotating a credential.
  Rotation = delete secret + re-run (commands in the task comments).
- `docker build` is skipped after the first run even if `src/` changed. Image
  delivery follows the "bump the tag" workflow documented in `../README.md`
  (`app_image` in `site.yml` + `spec.image` in `deployment.yaml`); this keeps
  the second-run requirement (changed=0) trivially true, which a
  rebuild-on-every-run design would break.

## Useful variations

```bash
# Dry list of what would run
ansible-playbook site.yml --list-tasks

# Only the cluster bootstrap (no image build/load)
ansible-playbook site.yml --skip-tags image
```

Note `--check` (dry run) is of limited value here: most tasks are plain CLI
probes guarded by `when`, which do execute under check mode as no-ops; the
probing logic still runs, so `--check` is a good smoke test but not truth.

## Vars you may want to override (with `-e`)

| Var | Default | Notes |
|-----|---------|-------|
| `app_image` | `griffin:0.1.0` | keep in sync with `apps/griffin/deployment.yaml` |
| `minikube_profile` | `minikube` | also the expected kubectl context |
| `minikube_driver` | `docker` | e.g. `virtualbox` on old hosts |
| `flux_operator_cli_enable` | `true` | set `false` on machines with the CLI preinstalled |
| `flux_operator_cli_arch` | `arm64` | `amd64` for Intel macs or most Linux hosts |
| `sops_age_keys_file` | `~/.config/sops/age/keys.txt` | SOPS private key location |
