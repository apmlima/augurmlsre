# Approach writeup — Augur SRE assignment

Notes on how this solution was built, what was deliberately chosen, what was
verified against authoritative sources, and what was deferred. Companion
files: [README.md](README.md) (how to run everything) and the assignment
prompt in [`../sre-assignment/README.md`](../sre-assignment/README.md).

The solution lives in this `solution/` folder. The skeleton folder
`../sre-assignment/` is otherwise untouched, with two deliberate hygiene
edits documented in § 4.3 (deleting its plaintext `secret.yaml` and dropping
that reference from its kustomization list).

---

## 0. Executive summary

Goal: deploy the `src/` Go app to a minikube cluster with FluxCD (via the
flux-operator), with the app secret encrypted in git using SOPS + age, and the
whole bootstrap automated in an Ansible playbook.

```
GitHub repo (apmlima/augurmlsre, main)
        │  Flux clones it via HTTPS + PAT (basic-auth secret `flux-system`)
        │  FluxInstance sync path: solution/clusters/minikube
        ▼
FluxInstance (managed by the flux-operator)
        │  generates GitRepository/flux-system + root Kustomization/flux-system
        ├─ Kustomization infrastructure → ./solution/infrastructure → cert-manager HelmRelease
        └─ Kustomization apps           → ./solution/apps → griffin
              (decryption: SOPS via the `sops-age` secret in flux-system)

host side: docker build solution/src → minikube image load griffin:0.1.0 → node runtime
```

Deliverables:

1. **A git repository with the end result** — this repository, with the full
   solution in `solution/` (manifests, SOPS config, encrypted secret, helm
   config, Dockerfile, Ansible playbook, verify script).
2. **A writeup** — this document.

Everything below is grouped per task from the assignment guide in my
execution order, because execution order was itself one of the problems to
solve (the README's observed ordering blocks on secrets creation; see § 1).

---

## 1. Cluster + Flux bootstrap (assignment step 1)

### 1.1 What the installation flow really needs

The provided flow is:

```bash
minikube start
flux-operator install -f clusters/minikube/flux-instance.yaml
flux-operator create secret basic-auth flux-system --username=$GITHUB_USER --password=$GITHUB_TOKEN
```

with the caveat *"the flux-operator install will hang until the secret is
created"*. The reason it blocks: the install applies the `FluxInstance` and
waits for readiness; the FluxInstance generates a `GitRepository` + root
`Kustomization` that clone the *private* repo, and sync cannot make progress
without the basic-auth secret, so readiness never arrives. My change (both in
the runbook in `README.md` and inside `ansible/site.yml`) is to **create the
secrets before the install**:

```
minikube start → kubectl create ns flux-system
              → create secret basic-auth (PAT)
              → create secret sops-age     (see § 4)
              → flux-operator install -f flux-instance.yaml
```

Same outcome, no hang, no timing ritual. The only ordering constraint —
`flux-system` must exist before the secrets — is satisfied with a tolerant
`kubectl create namespace` (expects `AlreadyExists` on re-runs).

### 1.2 Field choices in `flux-instance.yaml`

| Field | Value | Why |
|-------|-------|-----|
| `distribution.version` | `2.x` | the operator auto-updates within Flux 2.x; `distribution.artifact` (kept from the skeleton) additionally lets the operator pull hotfix manifest revisions from the stability channel |
| `sync.kind/url` | GitRepository, `https://github.com/apmlima/augurmlsre.git` | HTTPS+PAT is the smallest auth surface for a take-home (no SSH keypair to inject into the cluster). The repo remote already points here. |
| `sync.path` | `solution/clusters/minikube` | see § 1.3 |
| `sync.pullSecret` | `flux-system` | the name `flux-operator create secret basic-auth flux-system` creates |
| `sync.interval` | `30s` | fast dev loop on a single-node cluster; would be higher for shared environments |
| `components` | as provided | core four controllers + source-watcher |

### 1.3 Flux sync path semantics — the subtle detail

This is the most important correctness decision in the repo layout, and it is
easy to get silently wrong. I verified it against the flux-operator source
(it generates the sync objects from a template in
`internal/builder/templates.go`, `syncTmpl`):

- The generated **`GitRepository` has no `spec.path`**: its artifact is the
  **entire repository** (source-controller archives the whole clone).
- The generated root **`Kustomization`** (named `flux-system`, matching
  `flux bootstrap` conventions) gets **`spec.path = <sync.path>`**, resolved
  **relative to the repository root**.

Consequences for this assignment (the solution is nested inside a shared
repo):

1. `sync.path` must be `solution/clusters/minikube` — not `clusters/minikube`.
2. The child manifests that the root Kustomization applies
   (`solution/clusters/minikube/apps.yaml`, `infrastructure.yaml`) also carry
   `spec.path` values that are resolved against the *artifact root* (the repo
   root). So they must point into the nested folder too:
   - `apps.yaml` → `path: ./solution/apps`
   - `infrastructure.yaml` → `path: ./solution/infrastructure`

With the skeleton's `./apps` (written for a repo-root layout), artifact
building would fail with "path not found" — a genuinely confusing failure when
diagnosed only from inside the cluster. The rationale is documented in
comments next to the values themselves.

An alternative (considered, rejected): publish this solution as its own
repository root, which would keep paths shallow (`clusters/minikube`,
`./apps`). Rejected because the deliverable is "your own copy of this
repository" (this remote), and a two-repo split makes review and the follow-up
call harder. A nested layout in a monorepo works fine as long as the three
paths above are coherent.

### 1.4 Reconciliation configuration

Both child Kustomizations got explicit knobs, sized for a local exercise
rather than for a shared environment:

- `interval: 1m` on `apps` (fast feedback; infrastructure 10m is fine).
- `wait: true` + `timeout` — a failed rollout surfaces as a Kustomization
  condition instead of looking healthy while pods crash-loop.
- `prune: true` stays: git deletions clean the cluster, and Flux only owns
  objects it applied, so other tenants' objects are untouched.
- `apps.dependsOn: infrastructure` — the app does not use cert-manager, but a
  deterministic order keeps `kubectl events` meaningful and leaves the right
  shape for when the app starts consuming certs.

---

## 2. Image (assignment step 2)

### 2.1 What was wrong with the skeleton Dockerfile

```dockerfile
FROM ubuntu:latest                   # ~100 MB base, root user
RUN apt-get update && apt-get install -y wget curl git build-essential …
RUN wget https://go.dev/dl/go1.26.2.linux-${TARGETARCH}.tar.gz …
COPY . .
RUN go build -gcflags "all=-N -l" -ldflags "-compressdwarf=false" -o /app .
ENV APP_ENV=development DEBUG=true …
EXPOSE 8080 22 9090
ENTRYPOINT ["/app"]
```

Issues (each is a measurable SRE-review finding):

- **Build toolchain ships in the runtime image**: one image carries Go, gcc,
  wget plus a grab-bag of debug utilities (nano, htop, dnsutils, …). That
  bloats the attack surface (a shelled-in pod with network tools is a lateral
  movement target), the pull size, and the start latency — for an app whose
  runtime needs are a single static binary.
- **`ubuntu:latest`** is unpinned; a rebuild can silently change the base.
- **Debug build flags**: `CGO_ENABLED=1` + `-gcflags "all=-N -l"` deoptimize
  the binary and bloat it with debug symbols; the app is pure `net/http` (no
  cgo), and a container does not need DWARF.
- **Debug env defaults** (`APP_ENV=development`, `DEBUG=true`,
  `LOG_LEVEL=debug`) don't belong to a deployed image; runtime env belongs to
  the manifests.
- **`EXPOSE 22/9090`** has nothing listening on those ports.

### 2.2 The chosen Dockerfile

Multi-stage: `golang:1.26-alpine` builder → `distroless/static-debian12:nonroot`
runtime.

```dockerfile
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/app .
```

- The runtime image contains exactly what the app needs — the binary and
  nothing else (no shell, no package manager, TLS certs kept by distroless).
- BuildKit cache mounts make iteration fast without baking caches into
  layers; `$TARGETOS/$TARGETARCH` (BuildKit AutoFill ARGs) keep the build
  host-agnostic — on this Apple Silicon host it produces arm64 binaries, on
  Intel hosts amd64, without changing anything.
- `CGO_ENABLED=0` gives a static binary, which is what lets it run on
  `distroless/static`.
- `USER 65532` matches `runAsUser`/`runAsNonRoot` in the deployment; the
  container cannot run as root even if a future manifest asks for it.
- `.dockerignore` trims the context to `go.mod` + `main.go`: less cache
  churn, and no risk of shipping unrelated local files `COPY . .` style.

### 2.3 Making the image available to minikube — the choice that matters

Three mechanisms considered:

| Mechanism | Notes |
|-----------|-------|
| **`minikube image load` (chosen)** | build with docker on the host, `minikube image load griffin:0.1.0`; the image lands in the node's runtime under exactly the name the kubelet will resolve. Deterministic, no shell-env ceremony, works with any driver. |
| `eval $(minikube docker-env)` + build straight into the node daemon | brittle on modern minikube containerd nodes, and couples host build tooling with the cluster runtime. |
| `minikube image build` | builds inside the node; slower first builds, extra disk usage in the node. Fine fallback when no host daemon exists. |

The deployment uses `imagePullPolicy: IfNotPresent` with the bare
`griffin:0.1.0`. The kubelet normalizes the bare name to
`docker.io/library/griffin`, which is exactly how `minikube image load`
registers it — so the local image is matched and no registry is involved.

**Tag discipline** (the part people forget with `IfNotPresent`): a tag is a
cache key, not a version. To ship new code: bump the tag (`griffin:0.1.1`),
update `app_image` in `ansible/site.yml` and `spec.image` in
`deployment.yaml`, rebuild, `minikube image load`, push. Rejected
alternatives: `:latest` (kubelet may go fetch it), `imagePullPolicy: Never`
(does not help when the loaded tag is stale).

---

## 3. App manifests (assignment step 3)

### 3.1 Bug found in the skeleton

`apps/griffin/service.yaml` selector was `app: gryffin`; the deployment's pod
template labels are `app: griffin`. That Service would show **zero
Endpoints** and the connectivity demo would fail against a syntactically
correct Service. Fixed to `app: griffin`.

### 3.2 Deployment changes

- `image: griffin:0.1.0`, `imagePullPolicy: IfNotPresent` (rationale in § 2).
- `SECRET_TOKEN` wired via
  `secretKeyRef: {name: griffin-secret, key: SECRET_TOKEN, optional: false}`.
  Flux decrypts `secret.yaml` at reconcile time and deploys a normal Secret,
  so the pod consumes it through the standard secretKeyRef path.
  `optional: false` makes a missing key fail loudly instead of silently
  reporting `Secret loaded: no`.
- Probes kept from the skeleton — they are correct (`/healthz` on port name
  `http`, sane delays for a tiny Go server). Using the named port keeps them
  correct even if the numeric port changes later.
- Hardening:
  - pod `securityContext.runAsNonRoot: true`, `runAsUser: 65532` (matches the
    image `USER`), `seccompProfile: RuntimeDefault`;
  - container `allowPrivilegeEscalation: false`,
    `readOnlyRootFilesystem: true`, `capabilities: drop ALL` (a plain HTTP
    server on 8080 needs no capabilities);
  - `resources` requests/limits set, so scheduling and OOM behavior is
    deliberate rather than accidental.

### 3.3 Service type

Kept `ClusterIP`: the app has no external consumers, and the connectivity
proof uses `kubectl port-forward` (§ 5). `NodePort` +
`minikube service griffin` is documented as a browser-friendly alternative.

### 3.4 Kustomization tree

Structurally unchanged (`apps/kustomization.yaml` lists
namespace/deployment/service/secret). `clusters/minikube/apps.yaml` and
`infrastructure.yaml` now point into `solution/…` (§ 1.3), carry
`wait/timeout`, `apps.dependsOn: infrastructure`, and (only on `apps`) the
SOPS decryption block:

```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```

### 3.5 cert-manager (provided infrastructure, modernized)

The skeleton's `helmrelease.yaml` pinned `version: "v1.14.x"` with
`values.installCRDs: true`. Two improvements, both fact-checked against the
live chart (`charts.jetstack.io`, latest series v1.19.6 at the time of
writing, values inspected from the chart tarball):

- Bump to `v1.19.x` (semver wildcard lets helm-controller pick up patch
  releases without surprise minor jumps).
- `installCRDs` is deprecated in favor of `crds.enabled` (introduced around
  cert-manager v1.13; still present as a value in v1.19 but deprecated).
  Switched to `crds: {enabled: true, keep: true}` — `keep: true` adds the
  `helm.sh/resource-policy: keep` annotation so CRDs outlive release
  uninstalls, which is the right policy for CRDs.

---

## 4. SOPS + age (assignment step 4)

### 4.1 Key generation and where each half lives

1. Generated an **age keypair** with `age-keygen` (v1.3.2):
   - **private** → `~/.config/sops/age/keys.txt` (mode 0600, *outside* the
     repository, so the working tree is always safe to push);
   - **public** → pinned in `solution/.sops.yaml`.
2. `solution/.sops.yaml` keeps the skeleton's shape (`path_regex` for
   `*.yaml`, `encrypted_regex` for `data|stringData`) with the age recipient
   filled in.
3. The cluster receives the private key as the `sops-age` secret in
   `flux-system`; kustomize-controller decrypts files when a Kustomization
   declares `spec.decryption.provider: sops` + `secretRef`. Note the
   chicken-and-egg arrangement: Flux cannot deliver the key needed to decrypt
   what Flux syncs, so the secret is created **out-of-band** — by the Ansible
   bootstrap on a fresh machine, or one manual `kubectl` command.

`encrypted_regex: ^(data|stringData)$` restricts encryption to the secret
payloads: `metadata` (names, labels, annotations) stays plaintext, so
commits remain reviewable as YAML — only values are `ENC[…]` blobs.

### 4.2 The committed secret

`apps/griffin/secret.yaml` ships **already encrypted**. The token value was
minted inside the encryption pipeline only (`openssl rand -hex 24`, written
to a temp file, encrypted, temp file deleted): it was never printed, never
committed in plaintext, and is not referenced anywhere in this deliverable.
The app only reports *whether* the secret loaded, so the value itself never
needs to be shared.

Rotation / inspection (same commands are in `.sops.yaml` comments):

```bash
# view
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d solution/apps/griffin/secret.yaml

# rotate (opens $EDITOR on the plaintext, re-encrypts)
cd solution/apps/griffin
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops edit secret.yaml
```

`sops-age` cluster-secret rotation: replace the key file, delete the secret,
re-run the playbook (rotating the age keypair itself means re-encrypting all
sops files with the new public key — standard procedure, not automated here;
see § 7).

### 4.3 The plaintext-secrets trap (resolved before pushing)

`sre-assignment/apps/griffin/secret.yaml` originally contained a **plaintext**
secret ("mysupersecret") with a header marking it "DO NOT COMMIT UNENCRYPTED".
Pushing the repo as-is would have published that plaintext. Two changes were
made to remove the trap while keeping the skeleton buildable:

- the plaintext `secret.yaml` was **deleted** from the skeleton folder;
- the skeleton's `apps/griffin/kustomization.yaml` no longer references it
  (a short comment documents why, and points at the encrypted copy in
  `solution/apps/griffin/secret.yaml`).

`git history` still shows the file's plaintext in the original "Initial
commit", which is an argument for squash-rewriting before making the repo
public (or keeping it the honest, dated record of the take-home, with the
token classed as a throw-away example value — it is `mysupersecret`, not a
real credential).

---

## 5. Prove connectivity (assignment step 5)

`verify.sh` asserts the whole path in order:

1. `kubectl rollout status deployment/griffin` → pods are Ready.
2. `kubectl port-forward svc/griffin` → tunnels the ClusterIP service to
   `127.0.0.1`.
3. `curl /` and `curl /healthz`, asserting:
   - the body contains `Secret loaded: yes` — proof of the whole chain
     (SOPS-encrypted file → kustomize-controller decryption → Secret →
     secretKeyRef → process env);
   - the GREETING from the deployment manifest;
   - `/healthz` returns `ok`.

Manual equivalents are in the README. The `Secret loaded: yes` assertion is
the strongest one because it exercises every layer of the secret pipeline.

---

## 6. Ansible (assignment step 6)

Full run guide and idempotency table: `ansible/README.md`. Design summary:

**Scope**: replaces assignment steps 1–2 end-to-end and the Flux-side part of
step 4; then waits until the app is reconciled. One playbook, sectioned
pre-flight + tagged task groups (`minikube`, `image`, `flux`).

**Tooling**: runs against `localhost` (`connection: local`), and uses only
`ansible.builtin` modules — there are **no collections to install** (the
README requirement "document how to install them" is documented as
"none needed", with `requirements.yml` shipped as an explicit, empty
extension point). Kubernetes interaction is CLI-orchestrated
(`kubectl`, `flux-operator`); a `kubernetes.core` module variant was
considered and rejected: it adds a python `kubernetes` dependency on the
target for no idempotency win at this scale (the probe-then-mutate pattern
achieves the same).

**Idempotency**: every mutation is preceded by a probe of the target state
(the table in `ansible/README.md` lists each probe→mutate pair), so a second
run reports `changed=0` *by construction*. Highlights:

- `minikube start` runs only when the profile's Host state isn't `Running`
  (parsed from `minikube status -o json`);
- `docker build` / `minikube image load` run only when the image is missing
  on host / in node;
- `kubectl create namespace` tolerates `AlreadyExists` and counts as changed
  only on real creation;
- secrets and the operator install: `kubectl get` probe, create-if-missing;
- `kubectl apply flux-instance.yaml` doubles as drift-healing, and
  `changed_when` counts only `created`/`configured`;
- `wait`/rollout checks explicitly set `changed_when: false`.

**Secret hygiene**: `GITHUB_USER`/`GITHUB_TOKEN` come from environment
variables; the PAT is piped via `--password-stdin` (never on a command line,
which some systems expose through `ps`); every task touching either secret or
the age key is marked `no_log: true`, so values cannot leak into play logs; a
guard task fails with a clear message when credentials are needed but absent,
so idempotent re-runs don't require the token.

**Mutation safety**: before touching the cluster the playbook asserts
`kubectl config current-context == <minikube profile>` — it cannot point at
some other cluster by accident.

**Fresh-machine story**: with the assignment's prerequisites present, it ends
with Flux reconciling the app (waiting on GitRepository Ready →
infrastructure Ready → apps Ready → rollout). For machines missing the
flux-operator CLI, an opt-in block (`flux_operator_cli_enable`, default on)
fetches the pinned release (v0.61.0; asset naming verified against GitHub
releases) into `~/.local/bin`. Installing minikube/Docker/ansible themselves
from Ansible was deliberately out of scope — the preflight step instead fails
fast with an instruction list, which is a more honest model for a 1–2 hour
exercise.

**What it deliberately does not re-fix**: credential rotation (delete secret
→ re-run; documented in task comments), and `src/` code changes
(rebuild + bump the tag; a rebuild-on-every-run design would violate the
"second run reports no changes" requirement).

---

## 7. What I would do next (honest gaps)

By real-world SRE importance, kept out of scope of a 1–2 hour exercise:

1. **Alert wiring**: a Flux `Alert` + `Provider` to push reconciliation
   failures to Slack/PagerDuty — silent drift is the failure mode GitOps
   hides best.
2. **Image provenance**: digest-pin images, or adopt Flux image
   automation + ImagePolicy so "bump the tag" becomes automatic; SBOM + CVE
   scan in the build.
3. **Runtime secrets**: SOPS-in-git is fine for a small environment-scoped
   token; for real secrets, Vault / External Secrets / sealed-secrets with an
   explicit rotation story beats age-key juggling. (sops itself can also use
   HashiCorp Vault transit keys through the same kustomize-controller
   pipeline.)
4. **NetworkPolicies** for the app namespace (the Flux distribution got one
   via `networkPolicy: true`; the griffin pod did not).
5. **CI gates**: kubeconform strict, kyverno policies, and a plaintext-secret
   detector so an unencrypted `secret.yaml` can never reach main again
   (protects the skeleton folder too).
6. **Actually running the cluster** — see § 8 (this is the biggest gap).

---

## 8. What was verified locally vs deferred

This authoring environment had **no minikube / flux-operator / ansible / Go**
installed, and standing up the full stack was scoped as out-of-band for this
session, so:

**Verified locally during this work:**

- Every claim that could be fact-checked was checked against an authoritative
  source: the flux-operator generated-object template (fetched from
  `controlplaneio-fluxcd/flux-operator` on GitHub), sops v3.13.3 / age v1.3.2
  / flux-operator v0.61.0 release asset names (GitHub releases API), the
  cert-manager chart's current values for `installCRDs`/`crds.enabled`
  (pulled the v1.19.6 tarball from `charts.jetstack.io`).
- The SOPS pipeline was **actually executed** with scratch-dir binaries of
  sops+age: age keypair generated, `secret.yaml` encrypted in place, and
  decrypted again in a round-trip test (asserting the decrypted structure
  without ever printing the token value).
- Shell + YAML consistency checked (`bash -n` on `verify.sh`, plus a review
  pass over every manifest).

**Deferred to a live environment (the follow-up call checklist):**

- `minikube start`, image build/load, the full Flux reconcile of the
  solution — the Ansible playbook encodes each of these steps, and
  `README.md` documents every step's manual equivalent.
- `ansible-playbook site.yml` run twice (second run expected `changed=0`).
- `./solution/verify.sh` end-to-end connectivity proof.

Environment prep for the call:

```bash
brew install minikube flux-operator sops age kubectl ansible
# Docker Desktop running; then:
export GITHUB_USER=… GITHUB_TOKEN=…
git push
cd solution/ansible && ansible-playbook site.yml
cd .. && ./verify.sh
```
