#!/usr/bin/env bash

# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

# Runs tests for kubectl diff
run_kubectl_diff_tests() {
    set -o nounset
    set -o errexit

    create_and_use_new_namespace
    kube::log::status "Testing kubectl diff"

    # Test that it works when the live object doesn't exist
    output_message=$(! kubectl diff -f hack/testdata/pod.yaml)
    kube::test::if_has_string "${output_message}" 'test-pod'
    # Ensure diff only dry-runs and doesn't persist change
    kube::test::get_object_assert 'pod' "{{range.items}}{{ if eq ${id_field:?} \"test-pod\" }}found{{end}}{{end}}:" ':'

    kubectl apply -f hack/testdata/pod.yaml
    kube::test::get_object_assert 'pod' "{{range.items}}{{ if eq ${id_field:?} \"test-pod\" }}found{{end}}{{end}}:" 'found:'
    initialResourceVersion=$(kubectl get "${kube_flags[@]:?}" -f hack/testdata/pod.yaml -o go-template='{{ .metadata.resourceVersion }}')

    # Make sure that diffing the resource right after returns nothing (0 exit code).
    kubectl diff -f hack/testdata/pod.yaml

    # Ensure diff only dry-runs and doesn't persist change
    resourceVersion=$(kubectl get "${kube_flags[@]:?}" -f hack/testdata/pod.yaml -o go-template='{{ .metadata.resourceVersion }}')
    kube::test::if_has_string "${resourceVersion}" "${initialResourceVersion}"

    # Make sure that:
    # 1. the exit code for diff is 1 because it found a difference
    # 2. the difference contains the changed image
    # 3. the output doesn't indicate this is an error
    output_message=$(kubectl diff -f hack/testdata/pod-changed.yaml 2>&1 || test $? -eq 1)
    kube::test::if_has_string "${output_message}" 'registry.k8s.io/pause:3.4'
    kube::test::if_has_not_string "${output_message}" 'exit status 1'

    # Ensure diff only dry-runs and doesn't persist change
    resourceVersion=$(kubectl get "${kube_flags[@]:?}" -f hack/testdata/pod.yaml -o go-template='{{ .metadata.resourceVersion }}')
    kube::test::if_has_string "${resourceVersion}" "${initialResourceVersion}"

    # Test found diff with server-side apply
    output_message=$(kubectl diff -f hack/testdata/pod-changed.yaml --server-side || test $? -eq 1)
    kube::test::if_has_string "${output_message}" 'registry.k8s.io/pause:3.4'

    # Ensure diff --server-side only dry-runs and doesn't persist change
    resourceVersion=$(kubectl get "${kube_flags[@]:?}" -f hack/testdata/pod.yaml -o go-template='{{ .metadata.resourceVersion }}')
    kube::test::if_has_string "${resourceVersion}" "${initialResourceVersion}"

    # Test that we have a return code bigger than 1 if there is an error when diffing
    kubectl diff -f hack/testdata/invalid-pod.yaml || test $? -gt 1

    # Cleanup
    kubectl delete -f hack/testdata/pod.yaml

    kube::log::status "Testing kubectl diff after kubectl create (Bug #1587)"

    # Test that kubectl diff detects deletions even when resource was created with kubectl create
    # (without the last-applied-configuration annotation)

    # Create a deployment with env vars using kubectl create (without --save-config)
    kubectl create -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-diff-deployment
  labels:
    app: test-diff
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-diff
  template:
    metadata:
      labels:
        app: test-diff
    spec:
      containers:
      - name: nginx
        image: nginx:1.14
        env:
        - name: TESTENV1
          value: "var1"
        - name: TESTENV2
          value: "var2"
EOF

    kube::test::get_object_assert 'deployment test-diff-deployment' "{{.metadata.name}}" 'test-diff-deployment'

    # Verify that the deployment does NOT have the last-applied-configuration annotation
    output=$(kubectl get deployment test-diff-deployment -o jsonpath='{.metadata.annotations}' 2>&1 || true)
    kube::test::if_has_not_string "${output}" 'kubectl.kubernetes.io/last-applied-configuration'

    # Now test diff with a modified manifest that:
    # 1. Deletes TESTENV1
    # 2. Changes TESTENV2 value
    # This should detect BOTH changes (the deletion AND the value change)
    output_message=$(kubectl diff -f - 2>&1 <<EOF || test \$? -eq 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-diff-deployment
  labels:
    app: test-diff
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-diff
  template:
    metadata:
      labels:
        app: test-diff
    spec:
      containers:
      - name: nginx
        image: nginx:1.14
        env:
        - name: TESTENV2
          value: "modified"
EOF
)

    # Should show the warning about missing annotation
    kube::test::if_has_string "${output_message}" 'Warning'
    kube::test::if_has_string "${output_message}" 'last-applied-configuration'

    # IMPORTANT: Should now detect the deletion of TESTENV1
    kube::test::if_has_string "${output_message}" 'TESTENV1'

    # Should also detect the value change of TESTENV2
    kube::test::if_has_string "${output_message}" 'TESTENV2'
    kube::test::if_has_string "${output_message}" 'modified'

    # Cleanup
    kubectl delete deployment test-diff-deployment

    kube::log::status "Testing kubectl diff after kubectl create --save-config"

    # Test that it works correctly when --save-config is used
    kubectl create --save-config -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-diff-deployment-saved
  labels:
    app: test-diff-saved
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-diff-saved
  template:
    metadata:
      labels:
        app: test-diff-saved
    spec:
      containers:
      - name: nginx
        image: nginx:1.14
        env:
        - name: TESTENV1
          value: "var1"
        - name: TESTENV2
          value: "var2"
EOF

    kube::test::get_object_assert 'deployment test-diff-deployment-saved' "{{.metadata.name}}" 'test-diff-deployment-saved'

    # Verify that the annotation EXISTS when --save-config is used
    output=$(kubectl get deployment test-diff-deployment-saved -o jsonpath='{.metadata.annotations}')
    kube::test::if_has_string "${output}" 'kubectl.kubernetes.io/last-applied-configuration'

    # Test diff with deletion - should work without warning since annotation exists
    output_message=$(kubectl diff -f - 2>&1 <<EOF || test \$? -eq 1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-diff-deployment-saved
  labels:
    app: test-diff-saved
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-diff-saved
  template:
    metadata:
      labels:
        app: test-diff-saved
    spec:
      containers:
      - name: nginx
        image: nginx:1.14
        env:
        - name: TESTENV2
          value: "modified"
EOF
)

    # Should NOT show warning since annotation exists
    kube::test::if_has_not_string "${output_message}" 'Warning.*last-applied-configuration'

    # Should detect the deletion
    kube::test::if_has_string "${output_message}" 'TESTENV1'
    kube::test::if_has_string "${output_message}" 'TESTENV2'

    # Cleanup
    kubectl delete deployment test-diff-deployment-saved

    kube::log::status "Testing kubectl diff with server-side apply"

    # Test that kubectl diff --server-side works when the live object doesn't exist
    output_message=$(! kubectl diff --server-side -f hack/testdata/pod.yaml)
    kube::test::if_has_string "${output_message}" 'test-pod'
    # Ensure diff --server-side only dry-runs and doesn't persist change
    kube::test::get_object_assert 'pod' "{{range.items}}{{ if eq ${id_field:?} \"test-pod\" }}found{{end}}{{end}}:" ':'

    # Server-side apply the Pod
    kubectl apply --server-side -f hack/testdata/pod.yaml
    kube::test::get_object_assert 'pod' "{{range.items}}{{ if eq ${id_field:?} \"test-pod\" }}found{{end}}{{end}}:" 'found:'

    # Make sure that --server-side diffing the resource right after returns nothing (0 exit code).
    kubectl diff --server-side -f hack/testdata/pod.yaml

    # Make sure that for kubectl diff --server-side:
    # 1. the exit code for diff is 1 because it found a difference
    # 2. the difference contains the changed image
    output_message=$(kubectl diff --server-side -f hack/testdata/pod-changed.yaml || test $? -eq 1)
    kube::test::if_has_string "${output_message}" 'registry.k8s.io/pause:3.4'

    ## kubectl diff --prune
    kubectl create ns nsb
    kubectl apply --namespace nsb -l prune-group=true -f hack/testdata/prune/a.yaml
    kube::test::get_object_assert 'pods a -n nsb' "{{${id_field:?}}}" 'a'
    # Make sure that kubectl diff does not return pod 'a' without prune flag
    output_message=$(kubectl diff -l prune-group=true -f hack/testdata/prune/b.yaml || test $? -eq 1)
    kube::test::if_has_not_string "${output_message}" "name: a"
    # Make sure that for kubectl diff --prune:
    # 1. the exit code for diff is 1 because it found a difference
    # 2. the difference contains the pruned pod
    output_message=$(kubectl diff --prune -l prune-group=true -f hack/testdata/prune/b.yaml || test $? -eq 1)
    # pod 'a' should be in output, it is pruned
    kube::test::if_has_string "${output_message}" 'name: a'
    # apply b with namespace
    kubectl apply --prune --namespace nsb -l prune-group=true -f hack/testdata/prune/b.yaml
    # check right pod exists and wrong pod doesn't exist
    kube::test::wait_object_assert 'pods -n nsb' "{{range.items}}{{${id_field:?}}}:{{end}}" 'b:'
    # Make sure that diff --prune returns nothing (0 exit code) for 'b'.
    kubectl diff --prune -l prune-group=true -f hack/testdata/prune/b.yaml

    # Cleanup
    kubectl delete -f hack/testdata/pod.yaml
    kubectl delete -f hack/testdata/prune/b.yaml
    kubectl delete namespace nsb

    ## kubectl diff --prune with label selector
    kubectl create ns nsbprune
    kubectl apply --namespace nsbprune -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: a
  namespace: nsbprune
  labels:
    prune-group: "true"
spec:
  containers:
  - name: kubernetes-pause
    image: registry.k8s.io/pause:3.10.1
---
apiVersion: v1
kind: Pod
metadata:
  name: b
  namespace: nsbprune
  labels:
    prune-group: "true"
spec:
  containers:
    - name: kubernetes-pause
      image: registry.k8s.io/pause:3.10.1
---
apiVersion: v1
kind: Pod
metadata:
  name: c
  namespace: nsbprune
  labels:
    prune-group: "false"
spec:
  containers:
    - name: kubernetes-pause
      image: registry.k8s.io/pause:3.10.1
EOF
    kube::test::get_object_assert 'pods a -n nsbprune' "{{${id_field:?}}}" 'a'
    kube::test::get_object_assert 'pods b -n nsbprune' "{{${id_field:?}}}" 'b'
    kube::test::get_object_assert 'pods c -n nsbprune' "{{${id_field:?}}}" 'c'
    # Make sure that kubectl diff does not return either pod 'b' or pod 'c' without prune flag
    PRUNE=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: a
  namespace: nsbprune
  labels:
    prune-group: "true"
spec:
  containers:
  - name: kubernetes-pause
    image: registry.k8s.io/pause:3.10.1
---
apiVersion: v1
kind: Pod
metadata:
  name: c
  namespace: nsbprune
  labels:
    prune-group: "false"
spec:
  containers:
    - name: kubernetes-pause
      image: registry.k8s.io/pause:3.10.1
EOF
)
    output_message=$(echo "${PRUNE}" | kubectl diff -l prune-group=true -f -)
    kube::test::if_has_not_string "${output_message}" "name: b"
    kube::test::if_has_not_string "${output_message}" "name: c"
    # the exit code for diff is 1 because pod 'b' is found in the given label selector but not 'c'
    output_message=$(echo "${PRUNE}" | kubectl diff --prune -l prune-group=true -f - || test $? -eq 1)
    # pod 'b' should be in output, it is pruned. On the other hand, 'c' should not be, it's label selector is different
    kube::test::if_has_string "${output_message}" 'name: b'
    kube::test::if_has_not_string "${output_message}" "name: c"

    # Cleanup
    kubectl delete namespace nsbprune


    set +o nounset
    set +o errexit
}

run_kubectl_diff_same_names() {
    set -o nounset
    set -o errexit

    create_and_use_new_namespace
    kube::log::status "Test kubectl diff with multiple resources with the same name"

    output_message=$(KUBECTL_EXTERNAL_DIFF="find" kubectl diff -Rf hack/testdata/diff/)
    kube::test::if_has_string "${output_message}" 'v1\.Pod\..*\.test'
    kube::test::if_has_string "${output_message}" 'apps\.v1\.Deployment\..*\.test'
    kube::test::if_has_string "${output_message}" 'v1\.ConfigMap\..*\.test'
    kube::test::if_has_string "${output_message}" 'v1\.Secret\..*\.test'

    set +o nounset
    set +o errexit
}
