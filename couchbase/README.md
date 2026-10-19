# Running Couchbase in VMs on OpenShift

## Install
Ensure you have CNV, FRR and a version of OpenShift with UDN.

Review `./install.sh`, ensure the IP addresses we use will work in your env. We are peering with our baremetal bastion node. 

Update these fields

```
NAMESPACE="couchbase-cudn"
CB_USER="Administrator"
CB_PASS="Password123!"
SSH_PASS="couchbase"
SSH_USER="cloud-user"
ADDRESS="10.30.0.0/24"
IS_CUDN=true
```

Run `./install.sh`, this will deploy 12 Couchbase VMs and setup the Couchbase Cluster. 

Once the install completes, visit the couchbase web UI and create the `bench-bucket`

## Front database with API

If you want to test with a light-weight API service, deploy the `couchbase-go-api/couchbase-api-deployment-service.yaml`, this will use the default parameters above and front your database with an API service. You need to update the mmanifest before deploying (it needs to know the DB IP address endpoints).

Patch the service fronting the API to include an `external_ip`

```
[root@f17-h03-000-r670 couchbase]# oc get svc
NAME                TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)              AGE
cb-cluster          ClusterIP   None            <none>        8091/TCP,18091/TCP   4d21h
cb-go-api-service   ClusterIP   172.30.195.37   10.30.0.200   8080/TCP             4d19h
```

## Execute the workload in the same cluster

Deploy `workload-pod.yaml`, by default it will use the service. The `API_URL` can be overwritten by an env var.

### Setup

```
( OpenShift Cluster [ gatling ] -- > [ api - service ] - > [ couchbase-db ] ) 
```

## Execute the workload from external node from cluster

From the bastion node

Update the api-endpoint to match.

```
podman run --pull=always --rm -it   --net=host   --ulimit nofile=1048576:1048576  -e API_URL="http://10.30.0.200:8080"   -v $(pwd)/gatling-results:/app/results:Z   quay.io/jtaleric/couchbase-gatling:101526   /bin/sh -c 'java -server -Xms4G -Xmx12G \                                                                                                                                                                          
    --add-opens java.base/java.lang=ALL-UNNAMED \
    --add-opens java.base/java.nio=ALL-UNNAMED \
    --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
    -Dgatling.data.file.bufferSize=16384 \
    -cp "classes:test-classes:lib/*" \
    io.gatling.app.Gatling \
    -s com.couchbase.benchmark.CouchbaseApiGatlingSimulation \
    -rf /app/results'
```

### Setup

```
[ bastion - gatling in podman pod ] -- > ( OpenShift Cluster [ api - service ] - > [ couchbase-db ] ) 
```


## Results from our cluster

Review under results in `results-on-openshift/`. To see the HTML pages rendered, enter into the speecific result directory and run 

```
python3 -m http.server 8000
```
Then open your browser to `localhost:8000`
