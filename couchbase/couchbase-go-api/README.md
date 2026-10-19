# couchbase-go-api
```
.
├── Containerfile
├── couchbase-api-deployment.yaml
├── couchbase-go-api
├── go.mod
├── go.sum
├── main.go
└── README.md 
```

Update `couchbase-api-deployment.yaml` with the database endpoints - you can use the couchbase dashboard to find them.

To capture the endpoints : 

```
CB_CUDN_IPS=$(oc get pods -n couchbase-cudn -l app=couchbase -o json | \
  jq -r '.items[] | select(.metadata.name | test("couchbase-node-[1-6]")) | .metadata.annotations["k8s.ovn.org/pod-networks"] | fromjson | ."couchbase-cudn/couchbase-cudn".ip_addresses[0]' | \
  cut -d'/' -f1 | tr '\n' ',' | sed 's/,$//')
```
