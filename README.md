# Multi-region with Restate OSS

The attached helm values files give a base config for a two-region Restate cluster. 

## Prerequisites

### Kubernetes Clusters
Two Kubernetes clusters across different regions. If you like, you can use less clusters (eg, just one) and use separate namespaces, as a way to test out the config.

### Networking
All Restate nodes need to reach each other's 5122 port, including across region. This most likely requires a per-node NLB.
The easiest way to create a new NLB is likely by creating a LoadBalancer type Service for each node, but this may vary depending on your EKS setup:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: restate-0
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  ports:
  - name: node
    port: 5122
    protocol: TCP
    targetPort: 5122
  # this is important!
  publishNotReadyAddresses: true
  type: LoadBalancer
  selector:
    app: restate
    apps.kubernetes.io/pod-index: "0"
```

`publishNotReadyAddresses` must be set to true for any service that is used for node-to-node traffic; we want nodes to be able to find each other
even if they are not ready, to avoid bootstrap problems when bringing up a cluster that is currently down.

The globally-resolveable and reachable dns name (with protocol `http` and port `5122`) should be set as `RESTATE_ADVERTISED_ADDRESS`.
The best way to do this is to have the DNS names for a given region as identical except for a subdomain like `restate-0`, `restate-1` corresponding to the node ID.

### Metadata
Two region setups necessitate an external metadata store. In this config, we use single-region S3 (both regions speak to a particular S3 bucket which we will treat as global).
This can be changed to multiregion DynamoDB in future.

### Snapshot Buckets
Each region's nodes will use a regional snapshot bucket, with S3 cross-region replication to copy snapshots across regions.

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
                "arn:aws:s3:::$region2_bucket_name",
                "arn:aws:s3:::$metadata_bucket_name"
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
                "arn:aws:s3:::$region2_bucket_name/*",
                "arn:aws:s3:::$metadata_bucket_name/*"
            ],
            "Effect": "Allow"
        }
    ]
}
```

The role needs an appropriate trust policy such that each ServiceAccount can assume it (one statement for each of the two regions). With
a standard EKS IRSA setup, this looks like the following:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$account_id:oidc-provider/$oidc_provider_region_one"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$oidc_provider_region_one:aud": "sts.amazonaws.com",
          "$oidc_provider_region_one:sub": "system:serviceaccount:$namespace_region_one:restate"
        }
      }
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$account_id:oidc-provider/$oidc_provider_region_two"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "$oidc_provider_region_two:aud": "sts.amazonaws.com",
          "$oidc_provider_region_two:sub": "system:serviceaccount:$namespace_region_two:restate"
        }
      }
    }
  ]
}
```

You can get your $oidc_provider with `aws eks describe-cluster --name my-cluster --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///"`.

The name of the role should be inserted into both values files as the `eks.amazonaws.com/role-arn` annotation.

## Deploying
Create the AWS resources as above, edit your values files appropriately, and:
```bash
# in the first cluster
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm --version 1.3.2 --namespace restate-region1 --create-namespace -f ./values-region1.yaml
# in the second cluster
helm upgrade --install restate oci://ghcr.io/restatedev/restate-helm --version 1.3.2 --namespace restate-region2 --create-namespace -f ./values-region2.yaml
```