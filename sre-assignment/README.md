# Augur SRE take home assignment

Aim to spend 1-2 hours on this exercise. Keep notes as you go so that your approach and decisions
can be discussed. If you hit any roadblocks, feel free to document and move on. Make sure you
have the environment ready for a follow up call.

## Deliverables

- A git repository with the end result.
- A writeup in any form, describing your approach and solutions to the assignment. Be as explicit
as possible here, we want to see your reasoning.

## Context

You are given a [FluxCD](https://fluxcd.io/) GitOps structure for a single Kubernetes cluster running on minikube.

Your task is to deploy the application under src/ to the cluster using Flux. This will require setting up a repository
and pointing Flux to it. Start in `clusters/minikube/flux-instance.yaml`.

---

## What's provided

```
.sops.yaml                    # SOPS config — TODO
apps/griffin/                 # Skeleton manifests - TODO
clusters/minikube/            # Flux Kustomization resources
infrastructure/cert-manager/  # HelmRepository + HelmRelease for cert-manager
src/                          # Go source + Dockerfile - TODO
```

The Go app (`src/`) is a small HTTP server. It serves a greeting on `/` and a health
check on `/healthz`. It reads an optional `SECRET_TOKEN` environment variable from a
Kubernetes secret. When the secret is loaded the app prints `Secret loaded: yes`.

---

## Prerequisites

You'll need the following to complete this assignment:

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [flux-operator CLI](https://fluxoperator.dev/get-started/)
- [sops](https://github.com/getsops/sops)
- [age](https://github.com/FiloSottile/age)
- Docker
- kubectl
- A GitHub repository and PAT (other git forges may work and are acceptable, but you'll need to adjust as required)

---

## Task guide

### 1. Set up the cluster and bootstrap Flux

Start a minikube cluster and bootstrap FluxCD against your own copy of this
repository. Note that the flux-operator install will hang until the secret is created.

```bash
minikube start
export GITHUB_TOKEN=TODO
export GITHUB_USER=TODO
flux-operator install -f clusters/minikube/flux-instance.yaml
flux-operator create secret basic-auth flux-system \
  --namespace=flux-system \
  --username=$GITHUB_USER \
  --password=$GITHUB_TOKEN
```

Verify flux is reconciling correctly.

### 2. Build the application image and make it available to minikube

Build the Docker image from `src/` and ensure minikube can pull it. Document how this was done.
You may improve/change any number of things in the Dockerfile.

### 3. Complete the application manifests

The files under `apps/griffin/` have `TODO` comments and placeholder values.

- Set the correct image and pull policy in `deployment.yaml`
- Wire the `SECRET_TOKEN` environment variable from the Kubernetes secret
- Make any other changes you want

Let Flux reconcile your changes.

### 4. Encrypt the secret with SOPS

The `secret.yaml` file contains a plaintext secret. It must be encrypted before you
commit the actual secret you want to use. You'll need to:

- Generate an age keypair
- Update `.sops.yaml`
- Create the corresponding `sops-age` secret in the `flux-system` namespace so the
  kustomize-controller can decrypt at reconcile time. This will also require configuration on the `apps` Flux Kustomization.
- Encrypt `secret.yaml` with SOPS
- Commit the encrypted version and let flux reconcile

### 5. Prove connectivity

Once the app is running and the secret is loaded, demonstrate that you can reach
the application and the secret is loaded.

### 6. Automate the bootstrap with Ansible

Write an Ansible playbook, run against localhost, that replaces the manual
commands from steps 1 and 2. Structure it however you like and document how to
run it.

- Running it against a fresh machine should end with Flux reconciling the app.
- Running it a second time should report no changes.
- Secrets must not be committed or printed in the output.
- Use any collections you like, as long as you document how to install them.
