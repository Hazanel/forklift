#!/bin/bash
# HyperV Dual-Mode (SMB + iSCSI) Migration Setup Configuration
# Save this file before deleting CRC!
# Run this script after setting up a fresh CRC to recreate the environment.

set -e

# =============================================================================
# CONFIGURATION - UPDATE THESE VALUES AS NEEDED
# =============================================================================

# HyperV Host Settings
HYPERV_HOST_IP="192.168.1.218"       # No port needed - WinRM port is handled internally
HYPERV_USERNAME="Administrator"      # UPDATE with your username
HYPERV_PASSWORD="redhat123!"         # UPDATE with your password

# Transfer method: "smb" (default) or "iscsi"
HYPERV_TRANSFER_METHOD="iscsi"

# Image Registry Settings
REGISTRY="quay.io"
REGISTRY_ORG="ehazan"
REGISTRY_TAG="devel-amd64"

# Derived image names
CONTROLLER_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-controller:${REGISTRY_TAG}"
API_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-api:${REGISTRY_TAG}"
VALIDATION_IMAGE="${REGISTRY}/${REGISTRY_ORG}/forklift-validation:${REGISTRY_TAG}"
POPULATOR_CONTROLLER_IMAGE="${REGISTRY}/${REGISTRY_ORG}/populator-controller:${REGISTRY_TAG}"
HYPERV_POPULATOR_IMAGE="${REGISTRY}/${REGISTRY_ORG}/hyperv-populator:${REGISTRY_TAG}"

# Namespace
MTV_NAMESPACE="openshift-mtv"

# =============================================================================
# SETUP FUNCTIONS
# =============================================================================

install_crds() {
    echo "Installing OVAProviderServer CRD (required by controller)..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_ovaproviderservers.yaml

    echo "Updating Plans CRD..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_plans.yaml

    echo "Installing HyperVVolumePopulator CRD (for iSCSI mode)..."
    oc apply -f ~/repos/forklift/operator/config/crd/bases/forklift.konveyor.io_hypervvolumepopulators.yaml
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

    for i in {1..60}; do
        CSV_STATUS=$(oc get csv -n openshift-cnv -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
        echo "  CSV Status: ${CSV_STATUS:-Pending}"
        if [ "$CSV_STATUS" == "Succeeded" ]; then
            echo "CNV operator installed successfully!"
            break
        fi
        sleep 10
    done

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
  insecureSkipVerify: "true"  # For dev/testing - skip TLS verification
EOF
}

create_hyperv_provider() {
    echo "Creating HyperV provider (transfer method: ${HYPERV_TRANSFER_METHOD})..."
    if [ "${HYPERV_TRANSFER_METHOD}" == "iscsi" ]; then
        cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv
  namespace: ${MTV_NAMESPACE}
spec:
  type: hyperv
  url: "${HYPERV_HOST_IP}"
  secret:
    name: hyperv-provider-secret
    namespace: ${MTV_NAMESPACE}
  settings:
    hyperVTransferMethod: iscsi
EOF
    else
        cat <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: hyperv
  namespace: ${MTV_NAMESPACE}
spec:
  type: hyperv
  url: "${HYPERV_HOST_IP}"
  secret:
    name: hyperv-provider-secret
    namespace: ${MTV_NAMESPACE}
EOF
    fi
}

patch_forklift_with_custom_images() {
    echo "Patching ForkliftController CR with custom images..."

    oc patch forkliftcontroller forklift-controller -n ${MTV_NAMESPACE} --type='merge' -p "{
        \"spec\": {
            \"controller_image_fqin\": \"${CONTROLLER_IMAGE}\",
            \"api_image_fqin\": \"${API_IMAGE}\",
            \"validation_image_fqin\": \"${VALIDATION_IMAGE}\",
            \"populator_controller_image_fqin\": \"${POPULATOR_CONTROLLER_IMAGE}\",
            \"populator_hyperv_image_fqin\": \"${HYPERV_POPULATOR_IMAGE}\",
            \"virt_v2v_image_fqin\": \"${REGISTRY}/${REGISTRY_ORG}/forklift-virt-v2v:${REGISTRY_TAG}\"
        }
    }"

    echo "ForkliftController CR patched. Waiting for operator to reconcile..."

    echo "Injecting HYPERV_POPULATOR_IMAGE env var into populator controller..."
    oc set env deployment/forklift-volume-populator-controller \
        -n ${MTV_NAMESPACE} \
        HYPERV_POPULATOR_IMAGE="${HYPERV_POPULATOR_IMAGE}" 2>/dev/null || true
}

fix_controller_rbac() {
    echo "Fixing controller RBAC..."

    CLUSTERROLE=$(oc get clusterrolebindings -o custom-columns=NAME:.metadata.name,ROLE:.roleRef.name,SA:.subjects[0].name --no-headers 2>/dev/null | grep forklift-controller | head -1 | awk '{print $2}')

    if [ -z "$CLUSTERROLE" ]; then
        echo "Warning: Could not find forklift-controller ClusterRole. Skipping RBAC fix."
        return
    fi

    echo "Found ClusterRole: ${CLUSTERROLE}"

    if ! oc get clusterrole "${CLUSTERROLE}" &>/dev/null; then
        echo "Warning: ClusterRole ${CLUSTERROLE} not found. Skipping RBAC fix."
        return
    fi

    echo "RBAC patched. Restarting controller..."
    oc rollout restart deployment/forklift-controller -n ${MTV_NAMESPACE}
    oc rollout status deployment/forklift-controller -n ${MTV_NAMESPACE} --timeout=120s

    echo "Granting forklift-api auth-delegator role..."
    oc create clusterrolebinding forklift-api-sar \
        --clusterrole=system:auth-delegator \
        --serviceaccount=${MTV_NAMESPACE}:forklift-api 2>/dev/null || \
        echo "forklift-api-sar binding already exists."

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

    echo "Building controller..."
    make REGISTRY=${REGISTRY} REGISTRY_ORG=${REGISTRY_ORG} REGISTRY_TAG=${REGISTRY_TAG%-*} push-controller-image

    echo "Building populator-controller..."
    make REGISTRY=${REGISTRY} REGISTRY_ORG=${REGISTRY_ORG} REGISTRY_TAG=${REGISTRY_TAG%-*} push-populator-controller-image

    echo "Building hyperv-populator..."
    make REGISTRY=${REGISTRY} REGISTRY_ORG=${REGISTRY_ORG} REGISTRY_TAG=${REGISTRY_TAG%-*} push-hyperv-populator-image

    echo "All images built and pushed!"
}

# =============================================================================
# MAIN
# =============================================================================

echo "HyperV Dual-Mode Migration Setup"
echo "================================="
echo ""
echo "Configuration:"
echo "  HyperV Host:             ${HYPERV_HOST_IP}"
echo "  Transfer Method:         ${HYPERV_TRANSFER_METHOD}"
echo "  Controller Image:        ${CONTROLLER_IMAGE}"
echo "  Populator Controller:    ${POPULATOR_CONTROLLER_IMAGE}"
echo "  HyperV Populator Image:  ${HYPERV_POPULATOR_IMAGE}"
echo ""

read -p "Install OpenShift Virtualization (CNV) Operator? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_openshift_virtualization
fi

read -p "Install CRDs? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_crds
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

read -p "Fix controller RBAC? (y/n) " -n 1 -r
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
