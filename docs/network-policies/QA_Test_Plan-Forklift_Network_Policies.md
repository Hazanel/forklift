# 🧪 QA Test Plan: Forklift Network Policy Validation Guide

## 1. Introduction and Scope

This document details the test scenarios required to validate the functionality and security of the Forklift Network Policies. The primary goal is to confirm that all required communication paths for migration succeed (Positive Testing) and that unauthorized paths are actively blocked (Negative/Security Testing).

**Scope:** All 13 Network Policies for Forklift components and migration workloads.

**Prerequisites:**
1.  Forklift Operator and all core components deployed in a namespace (e.g., `openshift-mtv`).
2.  At least one Provider of each type configured: vSphere, oVirt, OpenStack, OVA.
3.  Access to run `oc exec`, `kubectl exec` and create temporary resources in the Forklift namespace.

---

## 2. Validation Testing Scenarios (Positive)

The following tests ensure all required functions work with the network policies enabled.

### 2.1. Provider Connectivity & Inventory Collection

| ID | Test Objective | Component Tested | Steps to Execute | Expected Result |
| :--- | :--- | :--- | :--- | :--- |
| P-01 | **vSphere Connectivity (443)** | Controller | Execute the `curl` command from the Controller pod to the vSphere API endpoint. | Connection is established (HTTP 400 or 401 response expected). |
| P-02 | **oVirt Connectivity (443)** | Controller | Execute the `curl` command from the Controller pod to the oVirt Engine API endpoint. | Connection is established (HTTP 401 response expected). |
| P-03 | **OpenStack Connectivity** | Controller | Execute the `curl` command from the Controller pod to a known OpenStack service port (e.g., 13000). | Connection is established (HTTP 200/401 response expected). |
| P-04 | **DNS Resolution** | Controller | Execute `nslookup github.com` from the Controller pod. | DNS resolves successfully (confirms 53 UDP/TCP egress). |
| P-05 | **Provider Status** | All | Verify all configured Providers (vSphere, oVirt, OpenStack) show the **"Ready"** status. | All Providers must transition to and stay in **"Ready"**. |

### 2.2. Core Service and Feature Testing

| ID | Test Objective | Component Tested | Steps to Execute | Expected Result |
| :--- | :--- | :--- | :--- | :--- |
| P-06 | **Admission Webhooks** | API | Create a new Provider (e.g., a dummy vSphere Provider) via the UI or CLI. | Creation succeeds; Webhook validation runs without timeout or failure. |
| P-07 | **Validation Service Access** | Controller | Run the authorized `curl` test from the Controller pod to Validation Service port 8181. | **SUCCESS**: JSON response with `rules_version` is returned. |
| P-08 | **Certificate Retrieval** | UI Plugin/API | In the UI, attempt to **"Retrieve Certificate"** for each Provider type. | The certificate is successfully retrieved and displayed for all Providers. |
| P-09 | **Monitoring Access** | Controller | Execute the `curl` command *within* the Controller pod to `http://localhost:2112/metrics`. | Metrics data (text format) is displayed, confirming the metrics port is functional. |

### 2.3. End-to-End Migration Validation

| ID | Test Objective | Component Tested | Policy Validated | Expected Result |
| :--- | :--- | :--- | :--- | :--- |
| P-10 | **vSphere Migration (Warm)** | Populators, Virt-v2v | `vsphere-xcopy-populator-policy`, `virt-v2v-policy` | Migration plan executes and completes **successfully**. **Port 902** and **443** access is implicitly confirmed. |
| P-11 | **oVirt Migration** | Populator, Virt-v2v | `ovirt-populator-policy`, `virt-v2v-policy` | Migration plan executes and completes **successfully**. **Port 54323** access is implicitly confirmed. |
| P-12 | **OpenStack Migration** | Populator, Image Converter | `openstack-populator-policy`, `image-converter-policy` | Migration plan executes and completes **successfully**. Disk population and conversion jobs succeed. |
| P-13 | **Pre/Post Hooks** | Hook Pods | `forklift-hooks-policy` | Execute a simple hook that curls an external HTTP/S endpoint. The hook completes **successfully** and reaches the external service. |

---

## 3. Security Validation Scenarios (Negative)

These tests ensure unauthorized components are blocked, proving the policies' security enforcement.

| ID | Test Objective | Component Tested | Security Policy Enforced | Steps to Execute | Expected Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| N-01 | **Unauthorized Validation Access** | Validation Service | **Label-Based Access Control** | **1. Create a dummy test pod** (without Forklift labels). **2. Run the `curl` test** to the Validation Service (8181) from the test pod. | **Failure:** `Connection timed out` (The policy must block the connection). |
| N-02 | **Image Converter Egress** | Image Converter | **Egress Isolation** | Manually run a short-lived pod matching the Image Converter label and attempt to `curl https://google.com`. | **Failure:** `Connection timed out` (The policy must prevent external access). |
| N-03 | **OVA Server Ingress** | OVA Server | **Ingress Restriction** | **1. Create a dummy test pod** (without `app: forklift-virt-v2v` label). **2. Attempt to `curl` the OVA Server** on port 8080. | **Failure:** `Connection timed out` (Only virt-v2v pods should be allowed access). |
| N-04 | **Unauthorized Port Access** | Validation Service | **Port Precision** | Run the authorized `curl` test (P-07) from the Controller, but target port **8182** (or any port other than 8181). | **Failure:** `Connection timed out` (Policy must only allow the exact port 8181). |

---

## 4. Policy Management & Diagnostics

| ID | Test Objective | Component Tested | Policy Validated | Steps to Execute | Expected Result |
| :--- | :--- | :--- | :--- | :--- | :--- |
| D-01 | **View Policy Status** | Kubernetes | Policy Deployment | Run `kubectl get networkpolicy -n <Forklift-Namespace>`. | All 13 Network Policies must be listed with current configuration. |
| D-02 | **Debug Isolation** | Controller | Policy Enforcement | **Temporarily delete `forklift-validation-service-policy`**. Rerun test N-01 (Unauthorized Access). | The connection should **succeed** temporarily, proving the policy was the active enforcement factor. **(MUST BE RE-APPLIED IMMEDIATELY)** |

**End of QA Test Plan**