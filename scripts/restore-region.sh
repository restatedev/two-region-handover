set -euo pipefail

region=$1
namespace=$2

nodes=$(kubectl -n $namespace exec restate-0 -- restatectl sql --json "select plain_node_id from nodes where location == '$1' order by plain_node_id" 2>/dev/null  | jq -r '[.[].plain_node_id] | join(",")')
metadataNodes=$(kubectl -n $namespace exec restate-0 -- restatectl sql --json "select plain_node_id from nodes where location == '$1' and metadata_server_state!='member' order by plain_node_id" 2>/dev/null  | jq -r '[.[].plain_node_id] | join(",")')
workerNodes=$(kubectl -n $namespace exec restate-0 -- restatectl sql --json "select plain_node_id from nodes where location == '$1' and worker_state!='active' order by plain_node_id" 2>/dev/null  | jq -r '[.[].plain_node_id] | join(",")')
logNodes=$(kubectl -n $namespace exec restate-0 -- restatectl sql --json "select plain_node_id from nodes where location == '$1' and storage_state!='read-write' order by plain_node_id" 2>/dev/null  | jq -r '[.[].plain_node_id] | join(",")')

echo "Restoring nodes $nodes"

if [[ -n $metadataNodes ]]; then
    echo "Adding nodes $metadataNodes to metadata cluster"

    kubectl -n $namespace exec restate-0 -- restatectl metadata-server add-node $metadataNodes
    kubectl -n $namespace exec restate-0 -- restatectl sql "select plain_node_id, metadata_server_state from nodes"
fi

if [[ -n $logNodes ]]; then
    echo "Setting $logNodes log-server state to read-write"

    kubectl -n $namespace exec restate-0 -- restatectl node set-storage-state --nodes $logNodes --storage-state read-write
    kubectl -n $namespace exec restate-0 -- restatectl sql "select plain_node_id, storage_state from nodes"
fi

if [[ -n $workerNodes ]]; then
    echo "Setting $workerNodes worker state to draining"

    kubectl -n $namespace exec restate-0 -- restatectl node set-worker-state --nodes $workerNodes --worker-state active
    kubectl -n $namespace exec restate-0 -- restatectl sql "select plain_node_id, worker_state from nodes"
fi

echo "Moving replication from node -> region"

kubectl -n $namespace exec restate-0 -- restatectl config set --yes --log-replication '{node: 3, region: 2}' --partition-replication '{region: 2}'

until [[ $(kubectl -n $namespace exec restate-0 -- restatectl sql --json "select log_id from logs_tail_segments where replication != '{node: 3, region: 2}'" 2>/dev/null | jq 'length') = "0" ]];
do
    sleep 5
done

echo Creating snapshots
kubectl -n $namespace exec restate-0 -- restatectl snapshot create
