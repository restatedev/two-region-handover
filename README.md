# Multi-region with Restate OSS

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

Now update the subnets in the `services.yaml` files to be subnets in the correct zone for those pods (look at other load balancers attached to the cluster if you need to find the full set of subnets).
Also update the `service.beta.kubernetes.io/aws-load-balancer-target-node-labels` annotation to select the right zone.
Then we can apply the services files:
```bash
# in the first cluster
kubectl -n restate-region1 apply -f additional-manifest/region1/services.yaml
# in the second cluster
kubectl -n restate-region2 apply -f additional-manifest/region2/services.yaml
```

Once the load balancers are created (check `kubectl describe service restate-` to see events), the dns records may take a couple of minutes to propagate and for caches to clear, which we have to wait for.
In the meantime the restate pods will occasionally restart as they haven't been provisioned yet - this is normal.
You can try resolving the dns records locally or while exec'ed into a pod with `curl -v`. Once they have propagated, we can provision the cluster:

```bash
kubectl -n restate-region1 exec -it restate-0 -- restatectl provision --yes
```

## Handing over between regions

Handover runbooks are work in progress, but some basic scripts can be seen in the `scripts` directory.
