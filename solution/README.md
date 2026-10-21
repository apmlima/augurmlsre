# Augur SRE assignment — solution

This folder is the completed implementation of the assignment described in
`../sre-assignment/README.md`. The approach, decisions and reasoning live in
[APPROACH.md](APPROACH.md) (deliverable #2 — a writeup); this file is
deliverable #1 (a runnable repository layout) plus the exact steps to run it.

```
solution/
├── .sops.yaml                              # SOPS creation rules (age public key)
├── .gitignore                              # keeps keys/scratch out of git
├── clusters/minikube/                      # what Flux actually syncs
│   ├── flux-instance.yaml                  # Flux distribution install + sync config
│   ├── infrastructure.yaml                 # Kustomization: ./solution/infrastructure
│   └── apps.yaml                           # Kustomization: ./solution/apps + SOPS decryption
├── infrastructure/cert-manager/            # HelmRepository + HelmRelease (jetstack)
├── apps/
│   └── griffin/                            # namespace/deployment/service/secret
│       └── secret.yaml                     # SOPS-encrypted (age)
├── src/                                    # Go app + hardened Dockerfile
├── ansible/                                # bootstrap playbook (README step 6)
│   ├── site.yml … ansible.cfg — inventory — requirements.yml …
│   └── README.md                           # how to run, idempotency design
└── verify.sh                               # connectivity + secret-proof script
```

## Prerequisites

Same as the assignment README: minikube, flux-operator CLI, sops, age, Docker
Desktop running, kubectl, a GitHub account + PAT with `repo` scope, and Ansible.
For Homebrew:

```bash
brew install minikube flux-operator sops age kubectl ansible
```

> One-time note for THIS machine: the SOPS/age keypair for this repo was
> already generated at `~/.config/sops/age/keys.txt` (private, 0600, never
> committed). Its public half is pinned in [.sops.yaml](.sops.yaml). See
> APPROACH.md § SOPS for the reasoning.

## 1. Repository + Flux sync configuration

The starting file was `sre-assignment/clusters/minikube/flux-instance.yaml`. The
completed one lives at [`clusters/minikube/flux-instance.yaml`](clusters/minikube/flux-instance.yaml):

- `url: https://github.com/apmlima/augurmlsre.git` (the remote configured for
  this git repo),
- `path: solution/clusters/minikube` — because the GitRepository artifact
  contains the whole repository and the root Kustomization path is
  repository-relative (this nuance is the single most important correctness
  detail in the task; see APPROACH.md § "Flux sync path semantics").
- the child manifests reference `./solution/apps` and
  `./solution/infrastructure` for the same reason.

Push the content first (Flux must be able to clone what it syncs):

```bash
git add solution/ && git commit -m "SRE assignment: complete solution"
git push -B main origin
```

⚠️ Skeleton hygiene: `sre-assignment/apps/griffin/secret.yaml` (which held the
plaintext example secret) has been **removed**, and the skeleton's
`kustomization.yaml` no longer references it — nothing unencrypted is left in
the repo. The encrypted, working version is in this folder.

## 2. Build the image and make it available to minikube

```bash
docker build -t griffin:0.1.0 ./solution/src
minikube image load griffin:0.1.0        # verify with: minikube image ls | grep griffin
```

Rationale: the kubelet resolves `griffin:0.1.0` to
`docker.io/library/griffin:0.1.0`, which is exactly the name under which
`minikube image load` registers it in the node runtime, so
`imagePullPolicy: IfNotPresent` never attempts a registry pull. The Dockerfile
was rewritten as a multi-stage `golang:1.26-alpine` → `distroless/static`
build; see APPROACH.md § "Image".

## 3. Run the Ansible bootstrap (covers steps 1→5 in one shot)

```bash
export GITHUB_USER=apmlima
export GITHUB_TOKEN=ghp_xxx      # PAT with repo scope; never echoed, never committed

cd solution/ansible
ansible-playbook site.yml
```

It starts minikube, builds/loads the image, creates both sync secrets
(basic-auth and `sops-age`) **before** the operator install (which is what
causes the README's hang if you do it in the observed order), installs the
flux-operator + FluxInstance, and waits for reconciliation end-to-end. Run it a
second time: expected result is `changed=0`. Details in
[ansible/README.md](ansible/README.md).

## 4. Prove connectivity

```bash
./solution/verify.sh
```

expected output tail:

```
-- GET / --
Greetings from deployment.yaml
Secret loaded: yes

PASS: app reachable on / and /healthz; SECRET_TOKEN loaded from the SOPS-encrypted secret.
```

`Secret loaded: yes` is the proof: the value came from the SOPS-encrypted
`secret.yaml`, decrypted in-cluster by kustomize-controller. Manual equivalent:

```bash
kubectl -n griffin port-forward svc/griffin 18080:80 &
curl http://127.0.0.1:18080/
```

## 5. Secret workflow (rotate / re-encrypt)

`apps/griffin/secret.yaml` ships already encrypted (age public key in
`.sops.yaml`). The committed token is a random value minted with
`openssl rand -hex 24`; the point is that nothing readable was committed:

```bash
# view (decrypt to stdout)
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d solution/apps/griffin/secret.yaml

# edit the values in $EDITOR and re-encrypt
cd solution/apps/griffin && SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops edit secret.yaml
```

Then push; Flux decrypts the new version at reconcile time (interval 1m).

## Notes & troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `flux-operator install` waits forever | the basic-auth secret is missing; create it first (the playbook does this ordering for you) |
| app stuck with old code after a change to `src/` | images are loaded by tag; bump the tag (`app_image` in `ansible/site.yml` **and** `spec.image` in `deployment.yaml`), rebuild + load, push |
| `ErrImagePullBackOff` / `ErrImageNeverPull` | image not loaded into the node: re-run step 2 |
| apps Kustomization `decryption failed` | `sops-age` secret missing in `flux-system`, or the age key in it no longer matches `.sops.yaml` |
| pods but Service returns nothing | check the Service selector (`app: griffin`) vs pod labels; the skeleton had a `gryffin` typo selector which this solution fixes |
