# Comprehensive Network Policy Testing Plan

**Date:** November 12, 2025  
**Namespace:** `openshift-mtv`  
**Objective:** Verify all Forklift network policies work correctly before full migration testing

---

## Overview

This testing plan validates each network policy individually, ensuring all components can communicate properly before attempting full migrations. Full migrations are the final validation step.

---

## Phase 1: Policy Application Verification

### Test 1.1: Verify All Policies Applied
**Objective:** Confirm all network policies are created and active

**Steps:**
```bash
kubectl get networkpolicies -n openshift-mtv
```

**Expected Result:**
- ✅ forklift-api-policy
- ✅ forklift-controller-policy
- ✅ forklift-validation-service-policy
- ✅ forklift-vddk-validation-policy
- ✅ forklift-ui-plugin-policy
- ✅ forklift-virt-v2v-policy
- ✅ forklift-ova-server-policy
- ✅ forklift-ovirt-populator-policy
- ✅ forklift-openstack-populator-policy
- ✅ forklift-vsphere-xcopy-populator-policy
- ✅ forklift-image-converter-policy
- ✅ forklift-hooks-policy

**Success Criteria:** All policies exist and are active

---

## Phase 2: Component-Level Testing

### Test 2.1: API Service Network Policy
**Policy:** `forklift-api-policy`  
**Status:** ✅ Already tested

**Quick Verification:**
- [x] DNS resolution works
- [x] Internal services accessible
- [x] Certificate retrieval works
- [x] Webhook functionality works
- [x] Provider creation works

**Reference:** See `docs/api-network-policy-test-report.md`

---

### Test 2.2: Controller Network Policy
**Policy:** `forklift-controller-policy`  
**Status:** ✅ Already tested

**Quick Verification:**
- [x] DNS resolution works
- [x] Internal services accessible
- [x] External provider connectivity works
- [x] OpenStack custom ports work
- [x] Provider inventory collection works

**Reference:** See `docs/controller-network-policy-test-report.md`

---

### Test 2.3: Validation Service Network Policy
**Policy:** `forklift-validation-service-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-validation-service-policy -n openshift-mtv
   ```

2. **Test Ingress from Controller:**
   ```bash
   CONTROLLER_POD=$(kubectl get pods -n openshift-mtv -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n openshift-mtv $CONTROLLER_POD -c main -- curl -k https://forklift-validation:8181/v1/data/io/konveyor/forklift/vsphere/rules_version
   ```
   **Expected:** JSON response with rules_version

3. **Test Ingress from API:**
   ```bash
   API_POD=$(kubectl get pods -n openshift-mtv -l service=forklift-api -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n openshift-mtv $API_POD -- curl -k https://forklift-validation:8181/v1/data/io/konveyor/forklift/vsphere/rules_version
   ```
   **Expected:** JSON response with rules_version

4. **Test Egress (should be unrestricted):**
   ```bash
   VALIDATION_POD=$(kubectl get pods -n openshift-mtv -l service=forklift-validation -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n openshift-mtv $VALIDATION_POD -- curl -k https://github.com -I
   ```
   **Expected:** HTTP/2 200 (if egress is open) or timeout (if restricted)

**Success Criteria:**
- ✅ Controller can access validation service
- ✅ API can access validation service
- ✅ Validation service responds correctly

---

### Test 2.4: VDDK Validation Policy
**Policy:** `forklift-vddk-validation-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-vddk-validation-policy -n openshift-mtv
   ```

2. **Check for Existing VDDK Validation Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l forklift.app=vddk-validation
   ```

3. **If No Pods Exist, Trigger Validation:**
   - Create/update a vSphere provider
   - VDDK validation pod should be created automatically

4. **Test Pod Communication:**
   ```bash
   VDDK_POD=$(kubectl get pods -n openshift-mtv -l forklift.app=vddk-validation -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$VDDK_POD" ]; then
     kubectl logs -n openshift-mtv $VDDK_POD --tail=50
   fi
   ```

**Success Criteria:**
- ✅ VDDK validation pod can communicate with controller
- ✅ Pod completes validation successfully
- ✅ No network-related errors in logs

---

### Test 2.5: UI Plugin Policy
**Policy:** `forklift-ui-plugin-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-ui-plugin-policy -n openshift-mtv
   ```

2. **Check UI Plugin Pod:**
   ```bash
   kubectl get pods -n openshift-mtv -l service=forklift-ui-plugin
   ```

3. **Test Ingress from Console:**
   - Access OpenShift Console
   - Navigate to Forklift plugin
   - Verify plugin loads without errors

4. **Test Egress (should be open):**
   ```bash
   UI_POD=$(kubectl get pods -n openshift-mtv -l service=forklift-ui-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$UI_POD" ]; then
     kubectl exec -n openshift-mtv $UI_POD -- curl -k https://github.com -I
   fi
   ```

**Success Criteria:**
- ✅ Console can access UI plugin
- ✅ Plugin loads and functions correctly
- ✅ No network-related errors

---

### Test 2.6: Virt-v2v Policy
**Policy:** `forklift-virt-v2v-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-virt-v2v-policy -n openshift-mtv
   ```

2. **Test with Existing Conversion Pod (if any):**
   ```bash
   V2V_POD=$(kubectl get pods -n openshift-mtv -l forklift.app=virt-v2v -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$V2V_POD" ]; then
     echo "=== Testing virt-v2v pod: $V2V_POD ==="
     kubectl exec -n openshift-mtv $V2V_POD -c virt-v2v -- curl -k https://10.6.46.248/sdk -I 2>&1 | head -3
   fi
   ```

3. **Verify Required Ports:**
   - Port 443: vSphere API
   - Port 902: vSphere NFC
   - Port 80: HTTP
   - Port 8080: OVA downloads
   - Port 53: DNS

**Success Criteria:**
- ✅ Policy applied correctly
- ✅ Pod can connect to vSphere (when pod exists)
- ✅ No network-related failures

**Note:** Full testing requires an active migration with virt-v2v pod

---

### Test 2.7: OVA Server Policy
**Policy:** `forklift-ova-server-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-ova-server-policy -n openshift-mtv
   ```

2. **Check for OVA Server Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l provider=ova-provider
   ```

3. **Test Ingress from Controller:**
   ```bash
   CONTROLLER_POD=$(kubectl get pods -n openshift-mtv -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')
   OVA_POD=$(kubectl get pods -n openshift-mtv -l provider=ova-provider -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$OVA_POD" ]; then
     kubectl exec -n openshift-mtv $CONTROLLER_POD -c main -- curl http://$OVA_POD:8080/test_connection
   fi
   ```

4. **Test NFS Access:**
   ```bash
   if [ -n "$OVA_POD" ]; then
     kubectl exec -n openshift-mtv $OVA_POD -- mount | grep nfs
   fi
   ```

**Success Criteria:**
- ✅ Controller can access OVA server
- ✅ OVA server can access NFS storage
- ✅ DNS resolution works

---

### Test 2.8: oVirt Populator Policy
**Policy:** `forklift-ovirt-populator-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-ovirt-populator-policy -n openshift-mtv
   ```

2. **Check for oVirt Populator Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l populator=ovirt
   ```

3. **Test Required Ports (when pod exists):**
   - Port 443: oVirt Engine API
   - Port 54323: oVirt imageio-daemon
   - Port 53: DNS

**Success Criteria:**
- ✅ Policy applied correctly
- ✅ Pod can connect to oVirt (when pod exists)
- ✅ No network-related failures

**Note:** Full testing requires an active oVirt migration

---

### Test 2.9: OpenStack Populator Policy
**Policy:** `forklift-openstack-populator-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-openstack-populator-policy -n openshift-mtv
   ```

2. **Check for OpenStack Populator Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l populator=openstack
   ```

3. **Test Required Ports (when pod exists):**
   ```bash
   POPULATOR_POD=$(kubectl get pods -n openshift-mtv -l populator=openstack -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$POPULATOR_POD" ]; then
     echo "=== Testing OpenStack Populator Ports ==="
     kubectl exec -n openshift-mtv $POPULATOR_POD -- curl -k https://rhos-d.infra.prod.upshift.rdu2.redhat.com:13000/v3 -I 2>&1 | head -3
   fi
   ```

**Success Criteria:**
- ✅ Policy applied correctly
- ✅ Pod can connect to OpenStack (when pod exists)
- ✅ All required ports accessible

**Note:** Full testing requires an active OpenStack migration

---

### Test 2.10: vSphere Xcopy Populator Policy
**Policy:** `forklift-vsphere-xcopy-populator-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-vsphere-xcopy-populator-policy -n openshift-mtv
   ```

2. **Check for vSphere Xcopy Populator Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l populator=vsphere-xcopy
   ```

**Success Criteria:**
- ✅ Policy applied correctly

**Note:** Full testing requires an active vSphere migration using Xcopy

---

### Test 2.11: Image Converter Policy
**Policy:** `forklift-image-converter-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-image-converter-policy -n openshift-mtv
   ```

2. **Check for Image Converter Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l forklift.app=image-converter
   ```

**Success Criteria:**
- ✅ Policy applied correctly

**Note:** Full testing requires an active OpenStack migration with disk conversion

---

### Test 2.12: Hooks Policy
**Policy:** `forklift-hooks-policy`  
**Status:** ⏳ To be tested

**Test Steps:**

1. **Verify Policy Applied:**
   ```bash
   kubectl get networkpolicy forklift-hooks-policy -n openshift-mtv
   ```

2. **Check for Hook Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l 'step in (PreHook,PostHook)'
   ```

3. **Test Required Access (when pod exists):**
   - DNS (port 53)
   - Controller (port 8443)
   - API (port 8443)
   - Kubernetes API (port 6443)
   - HTTPS (port 443)
   - HTTP (port 80)
   - All namespaces (for custom integrations)

**Success Criteria:**
- ✅ Policy applied correctly
- ✅ Hook pods can access required services (when pods exist)

**Note:** Full testing requires a migration plan with hooks configured

---

## Phase 3: Integration Testing

### Test 3.1: Provider Operations
**Objective:** Verify all provider types work with network policies

**Test Steps:**

1. **vSphere Provider:**
   ```bash
   kubectl get provider vmware-7 -n openshift-mtv -o jsonpath='{.status.phase}'
   ```
   **Expected:** Ready

2. **oVirt Provider:**
   ```bash
   kubectl get provider rhv -n openshift-mtv -o jsonpath='{.status.phase}'
   ```
   **Expected:** Ready

3. **OpenStack Provider:**
   ```bash
   kubectl get provider test-openstack-api-policy -n openshift-mtv -o jsonpath='{.status.phase}'
   ```
   **Expected:** Ready

4. **OCP Provider:**
   ```bash
   kubectl get provider host -n openshift-mtv -o jsonpath='{.status.phase}'
   ```
   **Expected:** Ready

**Success Criteria:**
- ✅ All providers remain Ready
- ✅ No network-related errors in provider status
- ✅ Inventory collection continues to work

---

### Test 3.2: Plan Creation and Validation
**Objective:** Verify plans can be created and validated

**Test Steps:**

1. **Create a Test Plan:**
   ```bash
   oc mtv create plan test-network-policy-plan \
     --source-provider vmware-7 \
     --target-provider host \
     --vms "test-vm-name"
   ```

2. **Verify Plan Status:**
   ```bash
   kubectl get plan test-network-policy-plan -n openshift-mtv -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
   ```
   **Expected:** True

3. **Check Validation:**
   ```bash
   kubectl get plan test-network-policy-plan -n openshift-mtv -o jsonpath='{.status.vms[*].concerns}'
   ```

**Success Criteria:**
- ✅ Plan created successfully
- ✅ Plan validation completes
- ✅ No network-related validation failures

---

### Test 3.3: Webhook Functionality
**Objective:** Verify webhooks work with network policies

**Test Steps:**

1. **Test Provider Validation Webhook:**
   ```bash
   oc mtv create provider test-webhook-provider --type vsphere --url https://invalid-url --username test --password test
   ```
   **Expected:** Webhook rejects invalid provider

2. **Test Plan Validation Webhook:**
   ```bash
   # Create plan with invalid configuration
   # Should be rejected by webhook
   ```

**Success Criteria:**
- ✅ Webhooks respond correctly
- ✅ Invalid resources are rejected
- ✅ Valid resources are accepted

---

## Phase 4: Migration Component Testing

### Test 4.1: Disk Transfer Initiation
**Objective:** Verify disk transfer can start

**Test Steps:**

1. **Start a Test Migration:**
   ```bash
   oc mtv start plan test-network-policy-plan
   ```

2. **Monitor DataVolumes:**
   ```bash
   kubectl get datavolumes -n openshift-mtv -l forklift.konveyor.io/plan=test-network-policy-plan
   ```

3. **Check Importer Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l cdi.kubevirt.io=importer | grep test-network-policy-plan
   ```

**Success Criteria:**
- ✅ DataVolumes created
- ✅ Importer pods start successfully
- ✅ No network-related pod startup failures

---

### Test 4.2: Populator Pod Functionality
**Objective:** Verify populator pods can transfer data

**Test Steps:**

1. **Monitor Populator Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l 'populator in (ovirt,openstack,vsphere-xcopy)'
   ```

2. **Check Pod Logs:**
   ```bash
   POPULATOR_POD=$(kubectl get pods -n openshift-mtv -l populator=ovirt -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$POPULATOR_POD" ]; then
     kubectl logs -n openshift-mtv $POPULATOR_POD --tail=50 | grep -i "error\|failed\|timeout"
   fi
   ```

**Success Criteria:**
- ✅ Populator pods start successfully
- ✅ Pods can connect to source providers
- ✅ Data transfer progresses without network errors

---

### Test 4.3: Guest Conversion Pod Functionality
**Objective:** Verify virt-v2v pods can perform conversion

**Test Steps:**

1. **Monitor Conversion Pods:**
   ```bash
   kubectl get pods -n openshift-mtv -l forklift.app=virt-v2v
   ```

2. **Check Pod Logs:**
   ```bash
   V2V_POD=$(kubectl get pods -n openshift-mtv -l forklift.app=virt-v2v -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
   if [ -n "$V2V_POD" ]; then
     kubectl logs -n openshift-mtv $V2V_POD -c virt-v2v --tail=100 | grep -i "error\|failed\|vddk\|vsphere"
   fi
   ```

**Success Criteria:**
- ✅ Conversion pods start successfully
- ✅ Pods can connect to vSphere via VDDK
- ✅ Conversion progresses without network errors

---

## Phase 5: Full Migration Testing (Final Step)

### Test 5.1: Complete vSphere Migration
**Objective:** Verify end-to-end vSphere migration works

**Prerequisites:**
- ✅ All previous tests passed
- ✅ Source VM is powered off cleanly
- ✅ Test plan created and validated

**Test Steps:**

1. **Start Migration:**
   ```bash
   oc mtv start plan <vsphere-plan-name>
   ```

2. **Monitor Migration Progress:**
   ```bash
   watch -n 5 'kubectl get plan <plan-name> -n openshift-mtv -o jsonpath="{.status.vms[*].phase}"'
   ```

3. **Check All Components:**
   - DataVolumes progress
   - Importer pods status
   - Conversion pods status
   - Final VM creation

**Success Criteria:**
- ✅ Disk transfer completes
- ✅ Guest conversion completes
- ✅ Target VM created successfully
- ✅ No network-related failures throughout migration

---

### Test 5.2: Complete oVirt Migration
**Objective:** Verify end-to-end oVirt migration works

**Test Steps:**
Similar to Test 5.1, but for oVirt provider

**Success Criteria:**
- ✅ oVirt populator pods work correctly
- ✅ Imageio transfer succeeds
- ✅ Migration completes successfully

---

### Test 5.3: Complete OpenStack Migration
**Objective:** Verify end-to-end OpenStack migration works

**Test Steps:**
Similar to Test 5.1, but for OpenStack provider

**Success Criteria:**
- ✅ OpenStack populator pods work correctly
- ✅ Image converter pods work (if needed)
- ✅ Migration completes successfully

---

## Phase 6: Negative Testing

### Test 6.1: Verify Port Restrictions
**Objective:** Confirm unauthorized ports are blocked

**Test Steps:**

1. **Test Blocked Port from API Pod:**
   ```bash
   API_POD=$(kubectl get pods -n openshift-mtv -l service=forklift-api -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n openshift-mtv $API_POD -- timeout 3 bash -c "curl http://google.com:8080" 2>&1
   ```
   **Expected:** Connection timeout (port blocked)

2. **Test Blocked Port from Controller Pod:**
   ```bash
   CONTROLLER_POD=$(kubectl get pods -n openshift-mtv -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n openshift-mtv $CONTROLLER_POD -c main -- timeout 3 bash -c "curl http://google.com:3306" 2>&1
   ```
   **Expected:** Connection timeout (port blocked)

**Success Criteria:**
- ✅ Unauthorized ports are correctly blocked
- ✅ Security is enforced

---

## Test Execution Checklist

### Pre-Testing
- [ ] All network policies applied
- [ ] All policies verified active
- [ ] Test environment ready
- [ ] Source providers ready

### Component Testing
- [ ] API policy tested
- [ ] Controller policy tested
- [ ] Validation service policy tested
- [ ] VDDK validation policy tested
- [ ] UI plugin policy tested
- [ ] Virt-v2v policy tested
- [ ] OVA server policy tested
- [ ] oVirt populator policy tested
- [ ] OpenStack populator policy tested
- [ ] vSphere Xcopy populator policy tested
- [ ] Image converter policy tested
- [ ] Hooks policy tested

### Integration Testing
- [ ] Provider operations verified
- [ ] Plan creation verified
- [ ] Webhook functionality verified

### Migration Component Testing
- [ ] Disk transfer initiation verified
- [ ] Populator pods verified
- [ ] Conversion pods verified

### Full Migration Testing (Final)
- [ ] Complete vSphere migration tested
- [ ] Complete oVirt migration tested
- [ ] Complete OpenStack migration tested

### Negative Testing
- [ ] Port restrictions verified

---

## Troubleshooting Guide

### Common Issues

1. **Pod Cannot Start:**
   - Check network policy podSelector matches pod labels
   - Verify ingress rules allow controller communication
   - Check DNS egress rules

2. **Connection Timeouts:**
   - Verify required ports are in egress rules
   - Check if source provider is accessible
   - Verify DNS resolution works

3. **Provider Stuck in Staging:**
   - Check controller can access provider endpoints
   - Verify all required ports are allowed
   - Check for dynamic port discovery issues (OpenStack)

4. **Migration Components Fail:**
   - Verify populator/converter policies applied
   - Check pod can access source provider
   - Verify internal cluster communication works

---

## Success Criteria Summary

**Overall Success:**
- ✅ All network policies applied and active
- ✅ All component tests pass
- ✅ Integration tests pass
- ✅ Migration component tests pass
- ✅ **At least one full migration completes successfully**
- ✅ Port restrictions enforced correctly

**Ready for Production:**
When all tests pass, especially the full migration tests, the network policies are ready for production use.

---

**Test Plan Version:** 1.0  
**Last Updated:** November 12, 2025  
**Author:** Network Policy Testing Team




