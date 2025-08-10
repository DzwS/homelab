default:
  just --list

ubuntu:
  ssh coder@192.168.178.76

get-kubeconfig:
  scp decoder@192.168.178.87:/etc/kubernetes/admin.conf ./kubeconfig

kube-main:
  ssh decoder@192.168.178.87

kube-worker1:
  ssh decoder@192.168.178.88

kube-worker2:
  ssh decoder@192.168.178.89

proxmox:
  ssh root@192.168.178.75

install_knative_operator:
  kubectl apply -f https://github.com/knative/operator/releases/download/knative-v1.16.1/operator.yaml

retrieve_headlamp_token:
  kubectl get secret headlamp-admin -n kube-system -o jsonpath="{.data.token}" | base64 --decode | xsel --clipboard

apply-storage:
  kubectl --kubeconfig=./kubeconfig apply -f yaml/local-storage-class.yaml -f yaml/vcluster-pv.yaml

# ArgoCD commands
argocd_port := "8080"
copy := if os() == "linux" { "xsel --clipboard" } else { "pbcopy" }
browse := if os() == "linux" { "xdg-open" } else { "open" }

launch_argo:
  #!/usr/bin/env bash
  echo "ArgoCD Admin Password (copied to clipboard):"
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | tee >({{copy}})
  echo ""
  echo "Getting ArgoCD LoadBalancer IP..."
  ARGO_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening ArgoCD UI at http://$ARGO_IP"
  sleep 2
  nohup {{browse}} http://$ARGO_IP >/dev/null 2>&1 &

argo_password:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

argo_sync_apps:
  kubectl apply -f gitops/clusters/homelab/

launch_vault:
  #!/usr/bin/env bash
  echo "Vault Root Token (copied to clipboard): root"
  echo "root" | {{copy}}
  VAULT_IP=$(kubectl get svc -n vault vault-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening Vault UI at http://$VAULT_IP:8200"
  sleep 2
  nohup {{browse}} http://$VAULT_IP:8200 >/dev/null 2>&1 &

launch_homepage:
  #!/usr/bin/env bash
  HOMEPAGE_IP=$(kubectl get svc -n homepage homepage -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening Homepage at http://$HOMEPAGE_IP"
  nohup {{browse}} http://$HOMEPAGE_IP >/dev/null 2>&1 &

# Launch Portainer UI
launch_portainer:
  #!/usr/bin/env bash
  PORTAINER_IP=$(kubectl get svc -n portainer portainer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "Opening Portainer at https://$PORTAINER_IP:9443"
  echo "Note: First time setup required - create admin user"
  nohup {{browse}} https://$PORTAINER_IP:9443 >/dev/null 2>&1 &

# ArgoCD sync management using official annotation approach
# Temporarily disable auto-sync for all applications
argo_suspend:
  #!/usr/bin/env bash
  echo "🛑 Disabling auto-sync for all ArgoCD applications..."
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Disabling auto-sync for: $app"
    # Add annotation to disable auto-sync temporarily
    kubectl annotate application $app -n argocd \
      argocd.argoproj.io/disable-auto-sync="true" --overwrite
  done
  echo "✅ Auto-sync disabled for all applications."
  echo "📝 Apps will show as OutOfSync but won't auto-reconcile."
  echo "💡 Manual sync is still possible if needed."

# Resume auto-sync for all applications
argo_resume:
  #!/usr/bin/env bash
  echo "▶️  Re-enabling auto-sync for all ArgoCD applications..."
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Enabling auto-sync for: $app"
    # Remove the disable-auto-sync annotation
    kubectl annotate application $app -n argocd \
      argocd.argoproj.io/disable-auto-sync- --overwrite
  done
  echo "✅ Auto-sync re-enabled for all applications."
  echo "🔄 Applications will now reconcile automatically."

# Alternative: Use compare-options to ignore differences
argo_ignore_diffs:
  #!/usr/bin/env bash
  echo "🔧 Configuring ArgoCD to ignore local differences..."
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Configuring: $app"
    kubectl patch application $app -n argocd --type='merge' \
      -p='{"spec":{"ignoreDifferences":[{"group":"*","kind":"*","jsonPointers":["/data","/spec"]}]}}'
  done
  echo "✅ ArgoCD will now ignore differences in data and spec fields."

# Remove ignore differences configuration
argo_track_diffs:
  #!/usr/bin/env bash
  echo "🔍 Resetting ArgoCD to track all differences..."
  for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}'); do
    echo "  Resetting: $app"
    kubectl patch application $app -n argocd --type='json' \
      -p='[{"op":"remove","path":"/spec/ignoreDifferences"}]' 2>/dev/null || true
  done
  echo "✅ ArgoCD will now track all differences again."

# Apply local changes from current branch (use after argo_disable_sync)
apply_local:
  #!/usr/bin/env bash
  echo "Applying local changes from current branch..."
  echo "📁 Applying apps..."
  kubectl apply -f apps/ 2>/dev/null || true
  echo "📁 Applying gitops/infra..."
  kubectl apply -f gitops/infra/ 2>/dev/null || true
  echo "✅ Local changes applied."

# Full workflow: suspend ArgoCD and test branch locally
test_branch:
  just argo_suspend
  just apply_local
  @echo "🧪 Branch testing mode enabled. Test your changes locally."
  @echo "⚠️  Remember to run 'just restore_argo' when done!"

# Restore ArgoCD control
restore_argo:
  just argo_resume
  @echo "🔄 ArgoCD will now sync from the main branch."
  @echo "🔃 Triggering sync for all apps..."
  @kubectl get applications -n argocd -o name | xargs -I {} kubectl patch {} -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Alternative: Stop ArgoCD controller entirely (nuclear option)
argo_stop:
  @echo "⏹️  Stopping ArgoCD application controller..."
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=0
  @echo "✅ ArgoCD controller stopped. No reconciliation will occur."
  @echo "📝 Apps will show OutOfSync but won't be reconciled."

# Start ArgoCD controller
argo_start:
  @echo "▶️  Starting ArgoCD application controller..."
  kubectl scale statefulset argocd-application-controller -n argocd --replicas=1
  @echo "✅ ArgoCD controller started. Reconciliation will resume."

# Check ArgoCD sync status for all applications
argo_status:
  @echo "📊 ArgoCD Application Status:"
  @echo "================================"
  @kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision | column -t
  @echo ""
  @echo "🔍 Controller Status:"
  @kubectl get statefulset argocd-application-controller -n argocd
  @echo ""
  @echo "📝 Sync Windows (if any):"
  @kubectl get appproject default -n argocd -o jsonpath='{.spec.syncWindows}' 2>/dev/null || echo "No sync windows configured"
