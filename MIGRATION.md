# Migration: Per-Node NLBs to Per-Region NLB

This document describes how to safely migrate a Restate cluster from the old networking model (one NLB per Restate pod) to the new model (one NLB per region using Gateway API + TCPRoute).

The migration is non-disruptive: the new NLBs are deployed alongside the old ones, validated, and then Restate is pointed at the new addresses. Old NLBs are removed last.

## Prerequisites

Before starting, confirm the following in each Kubernetes cluster:

1. **AWS Load Balancer Controller >= v2.13.3** with the `NLBGatewayAPI=true` feature gate enabled
2. **Gateway API CRDs installed** -- both the standard and experimental bundles (TCPRoute is in the experimental bundle):
   ```bash
   # Check if TCPRoute CRD exists
   kubectl get crd tcproutes.gateway.networking.k8s.io
   ```
3. **GatewayClass available** -- either use an existing one in the cluster or set `createGatewayClass: true` in the values (default). Check existing:
   ```bash
   kubectl get gatewayclasses
   ```
4. **Restate Helm chart version** -- confirm the installed version of the Restate Helm chart supports `command` and `args` overrides. Check the current version:
   ```bash
   helm list -n restate-region1
   ```

## Step 1: Deploy the new additional-manifest chart

Deploy the new chart in each region. This creates the Gateway, TCPRoutes, and ClusterIP Services. The single regional NLB will be provisioned by the AWS LB controller.

**The old per-node NLBs remain untouched at this point** -- Restate is still using them.

```bash
# In the region 1 cluster (or kubecontext)
helm upgrade --install additional-manifest ./additional-manifest/chart \
  -n restate-region1 \
  -f ./additional-manifest/values-region1.yaml

# In the region 2 cluster (or kubecontext)
helm upgrade --install additional-manifest ./additional-manifest/chart \
  -n restate-region2 \
  -f ./additional-manifest/values-region2.yaml
```

> **Note:** In QA and prod, regions run in separate EKS clusters. Switch kubecontext before running each command. In dev, the two regions are namespaces in the same cluster -- the migration steps are identical, just use different `-n` flags instead of switching kubecontext.

## Step 2: Wait for NLB provisioning

Check that the Gateway has been accepted and the NLB is being created:

```bash
kubectl -n restate-region1 get gateway restate-gateway
kubectl -n restate-region1 describe gateway restate-gateway
```

Look for the `Programmed` condition to be `True`. The NLB DNS name will appear in the Gateway status.

Wait for external-dns to create the DNS record for the regional NLB. This may take a few minutes. Verify:

```bash
dig region1.restate.yourdomain.com
```

Repeat for region 2 (switching kubecontext if needed).

## Step 3: Verify connectivity

We need to verify that every Restate pod can reach every other pod via the new regional NLBs. This means testing from every pod in every region, to every port on every region's NLB.

The test needs to prove end-to-end connectivity through the full chain: NLB listener -> TCPRoute -> ClusterIP Service -> correct Restate pod. We do this by hitting the Restate health endpoint through each NLB port and checking that we reach the expected node.

> **How this works in dev:** In dev, regions are namespaces in the same cluster. Traffic still goes out to the NLB (via its external DNS name) and back into the cluster to the target namespace's Service. The NLB doesn't care about namespaces. So the test is the same as cross-region -- it exercises the full external path.

### 3a. Test within region 1

From the region 1 kubecontext:

```bash
REGION1_DNS="region1.restate.yourdomain.com"
REGION1_NS="restate-region1"
PODS=$(kubectl -n $REGION1_NS get pods -l app=restate -o name | sed 's|pod/||')

echo "=== Testing region 1 NLB from all region 1 pods ==="
for pod in $PODS; do
  for port in 5122 5123 5124; do
    echo -n "$pod -> $REGION1_DNS:$port: "
    kubectl -n $REGION1_NS exec $pod -- \
      curl -s -m 5 "http://$REGION1_DNS:$port/restate/health" 2>/dev/null || echo "FAILED"
  done
done
```

### 3b. Test cross-region (region 1 pods -> region 2 NLB)

Still from the region 1 kubecontext:

```bash
REGION2_DNS="region2.restate.yourdomain.com"

echo "=== Testing region 2 NLB from all region 1 pods ==="
for pod in $PODS; do
  for port in 5122 5123 5124; do
    echo -n "$pod -> $REGION2_DNS:$port: "
    kubectl -n $REGION1_NS exec $pod -- \
      curl -s -m 5 "http://$REGION2_DNS:$port/restate/health" 2>/dev/null || echo "FAILED"
  done
done
```

### 3c. Repeat from region 2

Switch to the region 2 kubecontext (in dev, just change the namespace variable) and repeat 3a and 3b with the roles swapped -- test all region 2 pods reaching both region 1 and region 2 NLBs.

### What to expect

A successful response from Restate confirms the full chain is working -- the request went through the NLB, was routed by the TCPRoute to the correct ClusterIP Service, and reached the Restate pod. A timeout means something in the path is broken (NLB not routing, TCPRoute misconfigured, VPC endpoint missing, security group blocking, etc).

> **Note on false positives:** The new regional NLB has a different DNS name from the old per-pod NLBs, so a successful curl can only be going through the new Gateway API path. The old networking cannot give us a false positive here.

### 3d. Verify correct pod routing

To confirm that each port reaches the *right* pod (not just any pod), check the node identity in the response. From any pod:

```bash
for i in 0 1 2; do
  port=$((5122 + i))
  echo -n "Port $port (expect restate-$i): "
  kubectl -n $REGION1_NS exec restate-0 -- \
    curl -s -m 5 "http://$REGION1_DNS:$port/restate/health" 2>/dev/null
done
```

Each port should return a response identifying a different node. If two ports return the same node, the TCPRoute or Service selector is misconfigured.

## Step 4: Update Restate values and rolling restart

Once connectivity is verified, update the Restate Helm release to use the new advertised addresses.

The new `values-region*.yaml` files include a `command` wrapper that derives the advertised address port from the pod ordinal. The `RESTATE_REGION_DNS` env var provides the regional DNS name.

```bash
# In the region 1 cluster (or kubecontext)
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm \
  --version <CONFIRM_VERSION> \
  --namespace restate-region1 \
  -f ./values-region1.yaml

# In the region 2 cluster (or kubecontext)
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm \
  --version <CONFIRM_VERSION> \
  --namespace restate-region2 \
  -f ./values-region2.yaml
```

> **Note:** Confirm the Helm chart version with the customer before running. The current README uses `1.4.3` but this may have changed. The `oci://ghcr.io/restatedev/restate-helm` is the standard public Restate Helm chart that the customer already uses -- we are not publishing anything new here, just upgrading the existing release with updated values.

The StatefulSet will perform a rolling update automatically -- Kubernetes deletes and recreates pods one at a time with the new spec (`command` and `args` are mutable fields in the pod template, so no orphaning is needed). Each restarted pod will:
1. Run the command wrapper, computing its port as `5122 + ordinal`
2. Set `RESTATE_ADVERTISED_ADDRESS` to `http://<regional-dns>:<port>`
3. Register the new address in metadata (DynamoDB)
4. Other nodes will discover the new address and start using it

Monitor the rollout:

```bash
kubectl -n restate-region1 rollout status statefulset/restate
kubectl -n restate-region2 rollout status statefulset/restate
```

## Step 5: Verify cluster health

After all pods have restarted, verify that the cluster is healthy and all nodes are communicating:

```bash
# Check all nodes are visible and have the new advertised addresses
kubectl -n restate-region1 exec restate-0 -- restatectl sql \
  "select plain_node_id, name, location from nodes"

# Check log replication is healthy
kubectl -n restate-region1 exec restate-0 -- restatectl sql \
  "select log_id, replication from logs_tail_segments"
```

Also check pod logs for any connection errors -- nodes should be reaching each other on the new regional addresses.

## Step 6: Remove old per-node NLBs

**Do not proceed until you are confident the new setup is stable.**

Since the new additional-manifest chart replaces the old one (same Helm release name), the old `type: LoadBalancer` Services should have already been replaced by `type: ClusterIP` Services in Step 1. This means the AWS LB controller should have already deprovisioned the old per-node NLBs.

Verify no old LoadBalancer services remain:

```bash
kubectl -n restate-region1 get svc -o wide | grep LoadBalancer
kubectl -n restate-region2 get svc -o wide | grep LoadBalancer
```

If old NLBs persist as orphaned AWS resources (e.g. the old chart used a different Helm release name), clean them up manually via AWS console or CLI.

## Step 7: Clean up DNS

The old per-pod DNS records (e.g. `restate-0.two-region-demo-cluster.restate.region1.yourdomain.com`) should be garbage collected by external-dns once the corresponding Services are gone. Verify:

```bash
dig restate-0.two-region-demo-cluster.restate.region1.yourdomain.com
```

If records persist, remove them manually from your DNS provider.

## Rollback

If issues are encountered after Step 4 (Restate is using new addresses but something is broken):

1. Revert the `values-region*.yaml` files to the old versions (with per-pod `RESTATE_ADVERTISED_ADDRESS` and no command wrapper)
2. `helm upgrade` the Restate release with the old values -- pods will restart and re-register the old advertised addresses
3. The old per-node NLBs must still be in place for this to work, which is why **Step 6 should only be done once you are confident the new setup is stable**

If the issue is with the Gateway/NLB itself (Step 1-3), rollback is trivial -- just uninstall the new additional-manifest chart and redeploy the old one. Restate never changed its advertised addresses so nothing else is affected.
