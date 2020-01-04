# vault-k8s-demo

 Inspired by Hashicorp's blog post [Injecting Vault Secrets into Kubernetes Pods via a Sidecar](https://www.hashicorp.com/blog/injecting-vault-secrets-into-kubernetes-pods-via-a-sidecar/)

The demo provides a complete example for [Agent Sidecar Injector](https://www.vaultproject.io/docs/platform/k8s/injector/index.html) of [vault-k8s](https://github.com/hashicorp/vault-k8s).

Tools used in this demo
* kubectl (https://kubernetes.io/docs/reference/kubectl)
* helm (https://github.com/helm/helm)
  * helm-diff plugin (https://github.com/databus23/helm-diff)
* helmfile (https://github.com/roboll/helmfile)
* kind (https://github.com/kubernetes-sigs/kind)
* vault (https://www.vaultproject.io/)

Helm chart used in this demo
* vault-helm (https://github.com/hashicorp/vault-helm)

# Makefile help
```
Main targets:
  setup                       - Setup vault
  deploy                      - Deploy the example application
  demo                        - Dump the secret injected by vault agent

Cleaning targets:
  clean                       - Remove required tools and the kubeconfig
  destroy                     - Destroy the cluster and clean up
```

# How to run
```
make demo
```

If all things went well, you would see something like
```bash
Secret: 👇
postgres://$RANDOM_USERNAME:$RANDOM_PASSWORD@postgres:5432/appdb?sslmode=disable
```
