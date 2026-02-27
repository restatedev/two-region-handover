# Multi-region Restate on Kubernetes

This repo contains two things:

1. **`additional-manifest/`** -- a Helm chart that deploys the networking resources (Gateway, TCPRoutes, ClusterIP Services) for cross-region connectivity via a single NLB per region.
2. **`values-region{1,2}.yaml`** -- reference values for the [Restate Helm chart](https://github.com/restatedev/restate/tree/main/charts/restate-helm), showing how to configure the Restate StatefulSet for this networking setup. These are examples, not deployed by this repo.

## Architecture

A single Restate cluster is deployed across multiple Kubernetes clusters (one per region), each with its own Helm release. Cross-region networking is provided by a **single NLB per region** using the Kubernetes Gateway API and TCPRoute resources. Each Restate pod is exposed on a unique port (5122 + pod ordinal) on the regional NLB.

### How networking works

Each region has:
- **One Gateway** resource that provisions a single NLB with N listeners (one per Restate pod)
- **One TCPRoute** per pod, routing each NLB port to a ClusterIP Service selecting that specific pod
- **One ClusterIP Service** per pod, selecting by `apps.kubernetes.io/pod-index`

The advertised address for each node is `http://<regional-dns>:<5122+ordinal>`, derived at pod startup from the StatefulSet pod ordinal via a command wrapper.

## Prerequisites

### Kubernetes Clusters
Two or more Kubernetes clusters across different regions. You can also use a single cluster with separate namespaces to test (e.g. the dev environment).

### AWS Load Balancer Controller
- Version **>= v2.13.3**
- Feature gate `NLBGatewayAPI=true` must be enabled

### Gateway API CRDs
Both standard and experimental Gateway API CRDs must be installed. TCPRoute is in the experimental bundle:
```bash
kubectl get crd tcproutes.gateway.networking.k8s.io
```

### Networking
All Restate nodes need to reach each other's regional NLB. For regions without VPC peering, VPC endpoints (PrivateLink) are used -- one per region pair.

### Metadata
In production, metadata is stored in a global DynamoDB table (strongly consistent global tables). The Raft-based metadata config (`RESTATE_METADATA_CLIENT__ADDRESSES`) shown in this repo is for reference but is no longer used in prod.

### Snapshot Buckets
Each region's nodes use a regional S3 snapshot bucket, with S3 cross-region replication in both directions.

### IAM roles
A single IAM role can be used for both regions. It needs permissions to read and write objects in the S3 buckets:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "s3:ListBucket",
            "Resource": [
                "arn:aws:s3:::$region1_bucket_name",
                "arn:aws:s3:::$region2_bucket_name"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "s3:PutObject",
                "s3:GetObject"
            ],
            "Resource": [
                "arn:aws:s3:::$region1_bucket_name/*",
                "arn:aws:s3:::$region2_bucket_name/*"
            ],
            "Effect": "Allow"
        }
    ]
}
```

The role needs an appropriate trust policy such that each Restate pod can assume it. This will vary depending on your kiam (`podAnnotations`) or oidc-based (`serviceAccount` annotations) IAM setup in Kubernetes.

## Deploying for the first time

### 1. Deploy the Restate StatefulSets

Deploy the Restate Helm chart in each region using your own values files. See `values-region{1,2}.yaml` in this repo for reference -- in particular the `command`/`args` wrapper that derives `RESTATE_ADVERTISED_ADDRESS` from the pod ordinal, and the `RESTATE_REGION_DNS` env var.

### 2. Deploy the networking (additional-manifest chart)

Edit `additional-manifest/values-region{1,2}.yaml` with the appropriate DNS suffixes and security groups.

```bash
# In the first cluster
helm upgrade --install restate-networking ./additional-manifest/chart \
  -n restate-region1 \
  -f ./additional-manifest/values-region1.yaml

# In the second cluster
helm upgrade --install restate-networking ./additional-manifest/chart \
  -n restate-region2 \
  -f ./additional-manifest/values-region2.yaml
```

This creates the Gateway, TCPRoutes, and ClusterIP Services. Wait for the NLBs to be provisioned and DNS to propagate:

```bash
kubectl -n restate-region1 describe gateway restate-gateway
dig region1.restate.yourdomain.com
```

In the meantime the Restate pods will occasionally restart as they haven't been provisioned yet -- this is normal.

### 3. Provision the cluster

Once DNS has propagated and pods can reach each other:

```bash
kubectl -n restate-region1 exec -it restate-0 -- restatectl provision --yes \
  --log-provider replicated \
  --log-replication '{node: 3, region: 2}' \
  --partition-replication '{region: 2}'
```

## Migrating from per-node NLBs

If you are migrating from the old per-node NLB setup, see [MIGRATION.md](./MIGRATION.md) for a step-by-step guide.

## Handing over between regions

You can hand off between regions either with a script on your laptop (using `kubectl exec` to run `restatectl` commands in the cluster) or using Kubernetes Jobs to run a script inside the cluster.

### Running locally
First, ensure you are in the appropriate kubectl context to talk to either region. Then you can run a drain
operation with the command `./scripts/drain-region.sh region2 restate-region1`, where `region2` is the name of
the region that was provided to restate with the `RESTATE_LOCATION` env var, and `restate-region1` is the name
of the namespace in which a `restate-0` pod can be exec'ed into to run the operations. To drain, you likely want
to exec into the region that you are not draining, so you have confidence the other region is running,
but it doesn't strictly matter.

To restore, you can run `./scripts/restore-region.sh region2 restate-region2`. In this case, it likely makes more
sense to exec into the region you are restoring, which confirms it is running.

### Running in a Job
First, apply the ConfigMap `./jobs/region-scripts-configmap.yaml` to the namespaces of both regions.
Next, ensure that `RESTATECTL_ADDRESS` is set appropriately in `./jobs/{drain,restore}-region-{1,2}.yaml`.
Drain Jobs should use the restate-0 address of the region they are *not* draining, while restore Jobs should
use the restate-0 address of the region they are restoring.

Next, you can `kubectl create` the appropriate Job file to execute it. You can create the Jobs in either region,
and they don't need to be in the namespaces used for Restate, as long as the Pods created by the Job are able to
reach the `RESTATECTL_ADDRESS`.

```bash
# drain region-1 (apply into any namespace you like)
kubectl create -f jobs/drain-region-1.job.yaml
# restore region-1
kubectl create -f jobs/restore-region-1.job.yaml
```

Jobs and the pods they created (along with their logs) will be retained for an hour after completion.
If there is a failure Kubernetes will retry the script by creating new Pods up to 6 times.

> **Note:** The drain/restore job YAML files reference the old per-node NLB addresses in `RESTATECTL_ADDRESS`. Update these to use the new regional NLB addresses (e.g. `http://region2.restate.yourdomain.com:5122`) after migration.
