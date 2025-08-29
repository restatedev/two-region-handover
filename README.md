# Two-region handover with Restate OSS

This repo gives a config for a two-region Restate cluster.

## Prerequisites

### Kubernetes Clusters
Two Kubernetes clusters across different regions. If you like, you can use a single cluster and use separate namespaces, as a way to test out the config.

### Networking
All Restate nodes need to reach each other's 5122 port, including across region.
For this purpose we use a per-node NLB, but we specify a single subnet for each NLB so that we don't waste too many globally routable IPs.
Configuration for NLBs can be found in `additional-manifest` - we apply those after creating the Restate pods so we can pick the NLB subnets appropriately to match where Restate is scheduled.

Each NLB has its own DNS name managed by the external DNS controller. The globally-resolveable and reachable dns name (with protocol `http` and port `5122`) is set as `RESTATE_ADVERTISED_ADDRESS` for each node.

### Metadata
In this two region setup, all 6 nodes participate in the Raft-based replicated metadata store. When handing over between regions, we update the metadata cluster to be a 3 node cluster in a single region.

### Snapshot Buckets
Each region's nodes will use a regional snapshot bucket, with S3 cross-region replication set up in both directions to copy snapshots across regions.

### IAM roles
A single IAM role can be used for both regions if desired. It needs permissions to read and write objects in the S3 buckets:
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
Create the AWS resources as above, edit your values files appropriately, and:
```bash
# in the first cluster
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm --version 1.4.3 --namespace restate-region1 --create-namespace -f ./values-region1.yaml
# in the second cluster
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm --version 1.4.3 --namespace restate-region2 --create-namespace -f ./values-region2.yaml
```

Next note the assigned zones of your Restate pods:
```bash
# in the first cluster
ns=restate-region1; for pod in $(kubectl -n $ns get po -o name); do; node=$(kubectl get -n $ns $pod -o jsonpath="{.spec.nodeName}{\"\n\"}"); zone=$(kubectl get node $node -o jsonpath="{.metadata.labels.topology\.kubernetes\.io/zone}") ; echo "$ns $pod $zone"; done

# in the second cluster
ns=restate-region2; for pod in $(kubectl -n $ns get po -o name); do; node=$(kubectl get -n $ns $pod -o jsonpath="{.spec.nodeName}{\"\n\"}"); zone=$(kubectl get node $node -o jsonpath="{.metadata.labels.topology\.kubernetes\.io/zone}") ; echo "$ns $pod $zone"; done
```

Now we need to update the values in `additional-manifest/region{1,2}-values.yaml`. We need to specify:
1. A DNS suffix which matches the names provided in the main values files
2. A name suffix for the NLBs
3. A security group for the NLBs in the region to use. It needs to be able to receive traffic from Restate pods on 5122, and send traffic to nodes on the NodePort pods. You likely have a single such security group shared across all load balancers.
4. The zone assignments for the Restate pods; Helm will use these to ensure the NLBs are in the right zone.
5. The appropriate subnet for the NLB to assign IPs in for each zone.

Then we can apply the additional manifests:
```bash
# in the first cluster
helm upgrade --install  -n restate-region1 -f ./additional-manifest/values-region1.yaml  additional-manifest ./additional-manifest/chart
# in the second cluster
helm upgrade --install  -n restate-region2 -f ./additional-manifest/values-region2.yaml  additional-manifest ./additional-manifest/chart
```

Once the load balancers are created (check `kubectl describe service restate-` to see events), the dns records may take a couple of minutes to propagate and for caches to clear, which we have to wait for.
In the meantime the restate pods will occasionally restart as they haven't been provisioned yet - this is normal.
You can try resolving the dns records locally or while exec'ed into a pod with `curl -v`. Once they have propagated, we can provision the cluster:

```bash
# in the first cluster
kubectl -n restate-region1 exec -it restate-0 -- restatectl provision --yes --log-provider replicated --log-replication '{node: 3, region: 2}' --partition-replication '{region: 2}'
```

## Handing over between regions

You can hand off between regions either with a script on your laptop (using `kubectl exec` to run `restatectl` commands in the cluster) or using Kubernetes Jobs to run a script inside the cluster.

### Running locally
First, ensure you are in the appropriate kubectl context to talk to either region. Then you can run a drain
operation with the command ` ./scripts/drain-region.sh region2 restate-region1`, where `region2` is the name of
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
