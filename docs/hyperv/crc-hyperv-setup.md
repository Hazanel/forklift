# CRC Environment Setup for HyperV Provider Testing

This document captures all the environment issues encountered when testing the HyperV provider on CRC (CodeReady Containers) and how to resolve them.

## Prerequisites

1. **CRC installed and running with adequate resources**
   ```bash
   # Set resources BEFORE first start
   crc config set memory 16384
   crc config set cpus 6
   crc config set disk-size 100  # 100GB - important for migrations!
   
   crc start
   ```
   
   **Important:** The default CRC disk size (31GB) is often insufficient for VM migrations. virt-v2v uses significant ephemeral storage during conversion.

2. **oc CLI configured**
   ```bash
   eval $(crc oc-env)
   oc login -u kubeadmin -p $(crc console --credentials | grep kubeadmin | awk '{print $NF}')
   ```

## Required Fixes

### 0. Install Custom CRDs (Development Only)

The standard MTV operator (v2.8.x) does not include CRDs for `OVAProviderServer` and `HyperVProviderServer`. These are required for OVA and HyperV provider support and must be installed from the development branch:

```bash
# Install OVAProviderServer CRD
oc apply -f operator/config/crd/bases/forklift.konveyor.io_ovaproviderservers.yaml

# Install HyperVProviderServer CRD
oc apply -f operator/config/crd/bases/forklift.konveyor.io_hypervproviderservers.yaml
```

**Verify:**
```bash
oc get crd | grep -E "ovaprovider|hypervprovider"
```

Expected output:
```
hypervproviderservers.forklift.konveyor.io   <timestamp>
ovaproviderservers.forklift.konveyor.io      <timestamp>
```

**Note:** After installing the CRDs, restart the forklift-controller deployment:
```bash
oc rollout restart deployment/forklift-controller -n openshift-mtv
```

### 1. Security Context Constraints (SCC)

The `forklift-controller-scc` needs two modifications for virt-v2v pods to run:

#### Add `default` Service Account to forklift-controller-scc
The virt-v2v pods run as the `default` service account, which needs to be added to the SCC:

```bash
oc patch scc forklift-controller-scc --type='json' -p='[
  {"op": "add", "path": "/users/-", "value": "system:serviceaccount:openshift-mtv:default"}
]'
```

#### Add `default` Service Account to privileged SCC
The HyperV provider server pod requires privileged SCC to run with the correct fsGroup for SMB mounts:

```bash
oc adm policy add-scc-to-user privileged -z default -n openshift-mtv
```

#### Add localhost seccomp profile
The virt-v2v pods require the `localhost/profiles/unshare.json` seccomp profile:

```bash
oc patch scc forklift-controller-scc --type='json' -p='[
  {"op": "replace", "path": "/seccompProfiles", "value": ["runtime/default", "localhost/profiles/unshare.json"]}
]'
```

**Combined command:**
```bash
oc patch scc forklift-controller-scc --type='json' -p='[
  {"op": "add", "path": "/users/-", "value": "system:serviceaccount:openshift-mtv:default"},
  {"op": "replace", "path": "/seccompProfiles", "value": ["runtime/default", "localhost/profiles/unshare.json"]}
]'
```

**Verify:**
```bash
oc get scc forklift-controller-scc -o yaml | grep -A5 "users:"
oc get scc forklift-controller-scc -o yaml | grep -A3 "seccompProfiles"
```

### 2. SMB CSI Driver

The SMB CSI driver is required for HyperV provider storage.

#### Install via OperatorHub
```bash
# Create subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: smb-csi-driver
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  name: smb-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

#### Add SMB CSI node SA to privileged SCC
The SMB CSI driver node pods need privileged access:

```bash
oc adm policy add-scc-to-user privileged -z smb-csi-driver-node-sa -n openshift-cluster-csi-drivers
```

#### Create ClusterCSIDriver CR (if not auto-created)
```bash
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: smb.csi.k8s.io
spec:
  managementState: Managed
EOF
```

**Verify SMB CSI is running:**
```bash
oc get pods -n openshift-cluster-csi-drivers | grep smb
oc get csidrivers | grep smb
```

### 3. Controller Deployment Environment Variables

When using custom images, ensure the controller deployment has the correct environment variables:

```bash
# Check current env vars
oc get deployment forklift-controller -n openshift-mtv -o jsonpath='{.spec.template.spec.containers[?(@.name=="inventory")].env}' | jq .

# If HYPERV_PROVIDER_SERVER_IMAGE is missing, patch it:
oc patch deployment forklift-controller -n openshift-mtv --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/1/env/-",
    "value": {
      "name": "HYPERV_PROVIDER_SERVER_IMAGE",
      "value": "quay.io/ehazan/forklift-hyperv-provider-server:devel-amd64"
    }
  }
]'
```

### 4. ForkliftController CR Configuration

Use the correct field names in the ForkliftController CR:

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  # Use these field names (they map directly to Ansible variables):
  controller_image_fqin: "quay.io/ehazan/forklift-controller:devel-amd64"
  ova_provider_server_fqin: "quay.io/ehazan/forklift-ova-provider-server:devel-amd64"
  hyperv_provider_server_fqin: "quay.io/ehazan/forklift-hyperv-provider-server:devel-amd64"
  validation_image_fqin: "quay.io/ehazan/forklift-validation:devel-amd64"
  virt_v2v_image_fqin: "quay.io/ehazan/forklift-virt-v2v:devel-amd64"
```

**Note:** Do NOT use `hyperv_container_image` - use `hyperv_provider_server_fqin`.

### 5. Console Plugin

Enable the MTV console plugin:

```bash
oc patch console.operator.openshift.io cluster --type='json' -p='[
  {"op": "add", "path": "/spec/plugins/-", "value": "forklift-console-plugin"}
]'
```

**Verify:**
```bash
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

## Network Configuration

### SMB Share Access from CRC

CRC runs in a VM with limited network access. To access an SMB share on your host:

1. **Find the CRC VM's gateway IP:**
   ```bash
   crc ip  # Get CRC VM IP
   # The gateway is usually the host IP on the same network
   ```

2. **Ensure firewall allows SMB traffic:**
   ```bash
   sudo firewall-cmd --add-service=samba --permanent
   sudo firewall-cmd --reload
   ```

3. **Test SMB access from a pod:**
   ```bash
   oc run test-smb --rm -it --image=alpine -- sh -c "apk add samba-client && smbclient -L //192.168.1.218 -U ehazan"
   ```

## HyperV Provider Setup

### Create Provider Secret

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hyperv-smb-creds
  namespace: openshift-mtv
type: Opaque
stringData:
  username: "your-smb-username"
  password: "your-smb-password"
EOF
```

**Important:** Use `username` not `user` in the secret data.

### Create HyperV Provider

```bash
cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-local
  namespace: openshift-mtv
spec:
  type: hyperv
  url: "//192.168.1.218/VMShare"
  secret:
    name: hyperv-smb-creds
    namespace: openshift-mtv
EOF
```

### Verify Provider

```bash
# Check provider status - should show "Ready"
oc get provider hyperv-local -n openshift-mtv

# Check detailed provider status
oc get provider hyperv-local -n openshift-mtv -o jsonpath='{.status}' | jq .

# Check provider server pod is running
oc get pods -n openshift-mtv | grep hyperv

# Get the pod name
HYPERV_POD=$(oc get pods -n openshift-mtv -o name | grep hyperv | head -1)
echo "HyperV provider pod: $HYPERV_POD"

# Check provider server logs - should show "Processing OVF file"
oc logs -n openshift-mtv $HYPERV_POD | tail -20

# List files in the mounted SMB share
oc exec -n openshift-mtv $HYPERV_POD -- ls -la /hyperv/

# View OVF file content to verify VM metadata
oc exec -n openshift-mtv $HYPERV_POD -- cat /hyperv/v-2019.ovf | head -50

# Test the provider server API endpoints
oc exec -n openshift-mtv $HYPERV_POD -- wget -qO- http://localhost:8080/vms
oc exec -n openshift-mtv $HYPERV_POD -- wget -qO- http://localhost:8080/networks
oc exec -n openshift-mtv $HYPERV_POD -- wget -qO- http://localhost:8080/disks
```

**Provider is ready when:**
1. `oc get provider` shows `Ready` phase
2. Provider pod is `Running` (1/1)
3. Logs show `Processing OVF file: /hyperv/<your-vm>.ovf`
4. `/vms` endpoint returns VM data

## Common Issues and Solutions

### Issue: virt-v2v pod stuck in CreateContainerConfigError

**Cause:** SCC doesn't allow the required security context.

**Solution:** Apply the SCC fixes from section 1.

### Issue: SMB PVC stuck in Pending

**Cause:** SMB CSI driver not installed or not properly configured.

**Solution:** 
1. Install SMB CSI driver
2. Add node SA to privileged SCC
3. Create ClusterCSIDriver CR

### Issue: HyperV provider shows ValidationFailed

**Cause:** Secret format incorrect.

**Solution:** Ensure secret uses `username` key (not `user`).

### Issue: virt-v2v fails with "input.xml not found"

**Cause:** Wrong virt-v2v mode being used (in-place vs regular).

**Solution:** For OVA/HyperV, `ShouldUseV2vForTransfer()` should return `true`. Check that the controller image is up to date.

### Issue: virt-v2v pod evicted - ephemeral storage

**Cause:** CRC node runs out of disk space during migration.

**Error message:**
```
The node was low on resource: ephemeral-storage. Container virt-v2v was using XXXKi
```

**Solution:**
1. Increase CRC disk size before starting:
   ```bash
   crc config set disk-size 100
   crc delete  # Required to apply disk size change
   crc start
   ```
2. Clean up unused images and pods:
   ```bash
   oc adm prune images --confirm
   ```
3. Delete old PVCs and migrations:
   ```bash
   oc get pvc -n openshift-mtv -o name | xargs -r oc delete -n openshift-mtv
   ```

**Check disk pressure:**
```bash
oc get node crc -o jsonpath='{.status.conditions}' | jq '.[] | select(.type == "DiskPressure")'
```

### Issue: Operator reconciles and removes manual SCC changes

**Cause:** The operator continuously reconciles the SCC.

**Solution:** Either:
1. Update the operator template (`controller-scc.yml.j2`) and rebuild
2. Or apply the patches after each operator reconciliation

## Quick Setup Script

```bash
#!/bin/bash
# CRC HyperV Provider Quick Setup

NAMESPACE="openshift-mtv"
SMB_USER="your-username"
SMB_PASS="your-password"
SMB_SHARE="//192.168.1.218/VMShare"

# 1. Fix SCC
echo "Fixing SCC..."
oc patch scc forklift-controller-scc --type='json' -p='[
  {"op": "add", "path": "/users/-", "value": "system:serviceaccount:'$NAMESPACE':default"},
  {"op": "replace", "path": "/seccompProfiles", "value": ["runtime/default", "localhost/profiles/unshare.json"]}
]'

# 2. Add SMB CSI node SA to privileged
echo "Fixing SMB CSI permissions..."
oc adm policy add-scc-to-user privileged -z smb-csi-driver-node-sa -n openshift-cluster-csi-drivers 2>/dev/null || true

# 3. Create HyperV secret
echo "Creating HyperV secret..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hyperv-smb-creds
  namespace: $NAMESPACE
type: Opaque
stringData:
  username: "$SMB_USER"
  password: "$SMB_PASS"
EOF

# 4. Create HyperV provider
echo "Creating HyperV provider..."
cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-local
  namespace: $NAMESPACE
spec:
  type: hyperv
  url: "$SMB_SHARE"
  secret:
    name: hyperv-smb-creds
    namespace: $NAMESPACE
EOF

echo "Setup complete! Check provider status with:"
echo "  oc get provider hyperv-local -n $NAMESPACE"
```

## Cleanup

```bash
# Delete HyperV resources
oc delete provider hyperv-local -n openshift-mtv
oc delete secret hyperv-smb-creds -n openshift-mtv

# Delete any leftover PVCs
oc get pvc -n openshift-mtv -o name | grep hyperv | xargs -r oc delete -n openshift-mtv

# Delete any leftover PVs
oc get pv -o name | grep hyperv | xargs -r oc delete
```

