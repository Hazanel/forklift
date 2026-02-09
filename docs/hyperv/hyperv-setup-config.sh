#!/bin/bash
# HyperV Migration Setup Configuration
# Save this file before deleting CRC!
# Run this script after setting up a fresh CRC to recreate the environment.

set -e

# =============================================================================
# CONFIGURATION - UPDATE THESE VALUES AS NEEDED
# =============================================================================

# HyperV Host Settings
HYPERV_HOST_IP=       # No port needed - WinRM port is handled internally
HYPERV_USERNAME=      # UPDATE with your username
HYPERV_PASSWORD=         # UPDATE with your password
SMB_URL=    # SMB URL for VM storage

# Image Registry Settings
REGISTRY=
REGISTRY_ORG=
REGISTRY_TAG=

# Derived image names
HYPERV_PROVIDER_SERVER_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-hyperv-provider-server:${REGISTRY_TAG}"
CONTROLLER_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-controller:${REGISTRY_TAG}"
API_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-api:${REGISTRY_TAG}"
VALIDATION_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-validation:${REGISTRY_TAG}"

# Namespace
MTV_NAMESPACE="openshift-mtv"

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================

install_hyperv_crd() {
    echo "Installing HyperVProviderServer CRD..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_hypervproviderservers.yaml
    
    echo "Installing OVAProviderServer CRD (required by controller)..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_ovaproviderservers.yaml
    
    echo "Updating Plans CRD (for targetPowerState field)..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_plans.yaml
}

install_openshift_virtualization() {
    echo "Installing OpenShift Virtualization (CNV) Operator..."
    
    # Create namespace
    oc create namespace openshift-cnv --dry-run=client -o yaml | oc apply -f -
    
    # Create OperatorGroup
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
EOF

    # Create Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for CNV operator to be installed..."
    echo "This may take several minutes..."
    
    # Wait for CSV to be ready
    for i in {1..60}; do
        CSV_STATUS=$(oc get csv -n openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        echo "  CSV Status: ${CSV_STATUS:-Pending}"
        if [ "$CSV_STATUS" == "Succeeded" ]; then
            echo "CNV operator installed successfully!"
            break
        fi
        sleep 10
    done
    
    # Create HyperConverged CR to deploy CNV components
    echo "Creating HyperConverged CR..."
    cat <<EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  featureGates:
    enableCommonBootImageImport: false
EOF

    echo "Waiting for HyperConverged to be ready..."
    for i in {1..60}; do
        HC_STATUS=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
        echo "  HyperConverged Available: ${HC_STATUS:-Pending}"
        if [ "$HC_STATUS" == "True" ]; then
            echo "OpenShift Virtualization is ready!"
            break
        fi
        sleep 10
    done
}

install_smb_csi_driver() {
    echo "Installing CIFS/SMB CSI Driver Operator from OperatorHub..."
    
    # Create namespace
    oc create namespace openshift-smb-csi-driver --dry-run=client -o yaml | oc apply -f -
    
    # Create OperatorGroup
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-smb-csi-driver
  namespace: openshift-smb-csi-driver
spec:
  targetNamespaces:
    - openshift-smb-csi-driver
EOF

    # Create Subscription for the Red Hat CIFS/SMB CSI Driver Operator
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: smb-csi-driver-operator
  namespace: openshift-smb-csi-driver
spec:
  channel: stable
  installPlanApproval: Automatic
  name: smb-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "Waiting for CIFS/SMB CSI Driver Operator to install..."
    for i in {1..40}; do
        CSV_STATUS=$(oc get csv -n openshift-smb-csi-driver -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        echo "  [$i] CSV Status: ${CSV_STATUS:-Pending}"
        if [ "$CSV_STATUS" == "Succeeded" ]; then
            echo "CIFS/SMB CSI Driver Operator installed successfully!"
            break
        fi
        sleep 10
    done
    
    # Create the ClusterCSIDriver CR to deploy the driver
    cat <<EOF | oc apply -f -
apiVersion: csi.openshift.io/v1alpha1
kind: ClusterCSIDriver
metadata:
  name: smb.csi.k8s.io
spec:
  managementState: Managed
EOF

    echo "Waiting for SMB CSI driver pods to be ready..."
    for i in {1..30}; do
        READY=$(oc get pods -n openshift-smb-csi-driver -l app=smb-csi-driver-node -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        if [ -z "$READY" ]; then
            # Try alternate label
            READY=$(oc get pods -n openshift-smb-csi-driver --no-headers 2>/dev/null | grep -c "Running" || true)
        fi
        echo "  [$i] SMB CSI driver pods: ${READY:-Pending}"
        if [ "$READY" == "Running" ] || [ "$READY" -ge 1 ] 2>/dev/null; then
            echo "SMB CSI driver is ready!"
            break
        fi
        sleep 10
    done
}

create_hyperv_provider_secret() {
    echo "Creating HyperV provider secret..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hyperv-provider-secret
  namespace: ${MTV_NAMESPACE}
type: Opaque
stringData:
  username: "${HYPERV_USERNAME}"
  password: "${HYPERV_PASSWORD}"
  smbUrl: "${SMB_URL}"
  insecureSkipVerify: "true"  # For dev/testing - skip TLS verification
EOF
}

create_hyperv_provider() {
    echo "Creating HyperV provider..."
    cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv-ui
  namespace: ${MTV_NAMESPACE}
spec:
  type: hyperv
  url: "${HYPERV_HOST_IP}"
  secret:
    name: hyperv-provider-secret
    namespace: ${MTV_NAMESPACE}
EOF
}

patch_controller_with_hyperv_image() {
    echo "Patching controller with HyperV provider server image..."
    # IMPORTANT: The hyperv controller runs in the 'inventory' container, not 'main'.
    # It must be set on the inventory container or the provider server pod won't spawn.
    oc set env deployment/forklift-controller \
        HYPERV_PROVIDER_SERVER_IMAGE="${HYPERV_PROVIDER_SERVER_IMAGE}" \
        -n ${MTV_NAMESPACE} -c inventory
}

patch_forklift_with_custom_images() {
    echo "Patching ForkliftController CR with custom images..."
    
    # Patch the ForkliftController CR with all custom images
    oc patch forkliftcontroller forklift-controller -n ${MTV_NAMESPACE} --type='merge' -p "{
        \"spec\": {
            \"controller_image_fqin\": \"${CONTROLLER_IMAGE}\",
            \"api_image_fqin\": \"${API_IMAGE}\",
            \"validation_image_fqin\": \"${VALIDATION_IMAGE}\",
            \"hyperv_provider_server_fqin\": \"${HYPERV_PROVIDER_SERVER_IMAGE}\",
            \"virt_v2v_image_fqin\": \"${REGISTRY}/${REGISTRY_ORG}/forklift-virt-v2v:${REGISTRY_TAG}\"
        }
    }"
    
    echo "ForkliftController CR patched. Waiting for operator to reconcile..."
}

set_hyperv_provider_image_env() {
    echo "Setting HYPERV_PROVIDER_SERVER_IMAGE env var on controller inventory container..."
    
    # The operator may not propagate the hyperv_provider_server_fqin to the deployment
    # So we set the env var directly using oc set env (more robust than JSON patch)
    # IMPORTANT: The hyperv controller runs in the 'inventory' container, not 'main'.
    # Without -c inventory, the provider server pod will never be created.
    oc set env deployment/forklift-controller -n ${MTV_NAMESPACE} \
        HYPERV_PROVIDER_SERVER_IMAGE=${HYPERV_PROVIDER_SERVER_IMAGE} \
        -c inventory
    
    # VIRT_V2V_IMAGE is used by the plan controller which runs in the 'main' container
    echo "Setting VIRT_V2V_IMAGE env var on controller main container..."
    oc set env deployment/forklift-controller -n ${MTV_NAMESPACE} \
        VIRT_V2V_IMAGE=${REGISTRY}/${REGISTRY_ORG}/forklift-virt-v2v:${REGISTRY_TAG} \
        -c main
    
    echo "Controller deployment patched with env vars."
    echo "Waiting for controller to restart..."
    oc rollout status deployment/forklift-controller -n ${MTV_NAMESPACE} --timeout=120s
}

fix_controller_rbac() {
    echo "Fixing controller RBAC for CSI drivers..."
    
    # Find the OLM-managed ClusterRole for forklift-controller
    # The ClusterRoleBinding name contains the role name, so we extract the role from the binding
    CLUSTERROLE=$(oc get clusterrolebindings -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SA:.subjects[0].name --no-headers 2>/dev/null | grep forklift-controller | head -1 | awk '{print $2}')
    
    if [ -z "$CLUSTERROLE" ]; then
        echo "Warning: Could not find forklift-controller ClusterRole. Skipping RBAC fix."
        return
    fi
    
    echo "Found ClusterRole: ${CLUSTERROLE}"
    
    # Verify the ClusterRole exists
    if ! oc get clusterrole "${CLUSTERROLE}" &>/dev/null; then
        echo "Warning: ClusterRole ${CLUSTERROLE} not found. Skipping RBAC fix."
        return
    fi
    
    # Check if csidrivers permission already exists
    if oc get clusterrole "${CLUSTERROLE}" -o yaml 2>/dev/null | grep -q "csidrivers"; then
        echo "csidrivers permission already exists. Skipping."
        return
    fi
    
    # Add csidrivers permission
    echo "Adding csidrivers permission to ClusterRole..."
    oc patch clusterrole "${CLUSTERROLE}" --type=json -p '[
        {"op": "add", "path": "/rules/-", "value": {"apiGroups": ["storage.k8s.io"], "resources": ["csidrivers"], "verbs": ["get", "list", "watch"]}}
    ]'
    
    echo "RBAC patched. Restarting controller..."
    oc rollout restart deployment/forklift-controller -n ${MTV_NAMESPACE}
    oc rollout status deployment/forklift-controller -n ${MTV_NAMESPACE} --timeout=120s
    
    # Grant forklift-api permission to create subjectaccessreviews (needed for admission webhook)
    echo "Granting forklift-api auth-delegator role..."
    oc create clusterrolebinding forklift-api-sar \
        --clusterrole=system:auth-delegator \
        --serviceaccount=${MTV_NAMESPACE}:forklift-api 2>/dev/null || \
        echo "forklift-api-sar binding already exists."
    
    # Grant forklift-controller SCC permissions for virt-v2v pods
    echo "Granting SCC permissions for virt-v2v pods..."
    oc adm policy add-scc-to-user forklift-controller-scc -z forklift-controller -n ${MTV_NAMESPACE} 2>/dev/null || true
    oc adm policy add-scc-to-user privileged -z forklift-controller -n ${MTV_NAMESPACE} 2>/dev/null || true
}

create_nad() {
    echo "Creating NetworkAttachmentDefinition in ${MTV_NAMESPACE}..."
    cat <<EOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: hyperv-net
  namespace: ${MTV_NAMESPACE}
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "hyperv-net",
    "type": "cnv-bridge",
    "bridge": "br0",
    "macspoofchk": false,
    "ipam": {}
  }'
EOF
    echo "NAD 'hyperv-net' created in ${MTV_NAMESPACE}."
}

build_and_push_images() {
    echo "Building and pushing custom images..."
    cd ~/repos/forklift
    
    echo "Building hyperv-provider-server..."
    make build-hyperv-provider-server-image push-hyperv-provider-server-image
    
    echo "Building controller..."
    make build-controller-image push-controller-image
    
    echo "Building API..."
    make build-api-image push-api-image
    
    echo "Building validation..."
    make build-validation-image push-validation-image
    
    echo "All images built and pushed!"
}

# =============================================================================
# MAIN
# =============================================================================

echo "HyperV Migration Setup"
echo "======================"
echo ""
echo "Configuration:"
echo "  HyperV Host:       ${HYPERV_HOST_IP}"
echo "  SMB URL:           ${SMB_URL}"
echo "  Provider Image:    ${HYPERV_PROVIDER_SERVER_IMAGE}"
echo "  Controller Image:  ${CONTROLLER_IMAGE}"
echo "  API Image:         ${API_IMAGE}"
echo "  Validation Image:  ${VALIDATION_IMAGE}"
echo ""

read -p "Install OpenShift Virtualization (CNV) Operator? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_openshift_virtualization
fi

read -p "Install HyperV CRD? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_hyperv_crd
fi

read -p "Install CIFS/SMB CSI Driver Operator (Red Hat)? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_smb_csi_driver
fi

read -p "Build and push all custom images? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    build_and_push_images
fi

read -p "Patch Forklift deployments with custom images? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    patch_forklift_with_custom_images
fi

read -p "Set HYPERV_PROVIDER_SERVER_IMAGE env var on controller? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    set_hyperv_provider_image_env
fi

read -p "Fix controller RBAC for CSI drivers? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    fix_controller_rbac
fi

read -p "Create NetworkAttachmentDefinition (NAD) in ${MTV_NAMESPACE}? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_nad
fi

read -p "Create HyperV provider secret? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_hyperv_provider_secret
fi

read -p "Create HyperV provider? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    create_hyperv_provider
fi

echo ""
echo "Setup complete! Check provider status with:"
echo "  oc get providers -n ${MTV_NAMESPACE}"
echo "  oc get pods -n ${MTV_NAMESPACE}"
