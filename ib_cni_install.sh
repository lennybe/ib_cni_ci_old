#!/bin/bash -x

export RECLONE=${RECLONE:-true}
export WORKSPACE=${WORKSPACE:-/tmp/k8s_$$}
export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts
export TIMEOUT=${TIMEOUT:-300}
export POLL_INTERVAL=${POLL_INTERVAL:-10}

# can be <latest_stable|master|vA.B.C>
export KUBERNETES_VERSION=${KUBERNETES_VERSION:-latest_stable}
export KUBERNETES_BRANCH=${KUBERNETES_BRANCH:-master}

export MULTUS_CNI_REPO=${MULTUS_CNI_REPO:-https://github.com/intel/multus-cni}
export MULTUS_CNI_BRANCH=${MULTUS_CNI_BRANCH:-master}
# ex MULTUS_CNI_PR=345 will checkout https://github.com/intel/multus-cni/pull/345
export MULTUS_CNI_PR=${MULTUS_CNI_PR:-''}

export SRIOV_CNI_REPO=${SRIOV_CNI_REPO:-https://github.com/intel/sriov-cni}
export SRIOV_CNI_BRANCH=${SRIOV_CNI_BRANCH:-master}
export SRIOV_CNI_PR=${SRIOV_CNI_PR:-''}

export PLUGINS_REPO=${PLUGINS_REPO:-https://github.com/containernetworking/plugins.git}
export PLUGINS_BRANCH=${PLUGINS_BRANCH:-master}
export PLUGINS_BRANCH_PR=${PLUGINS_BRANCH_PR:-''}

export SRIOV_NETWORK_DEVICE_PLUGIN_REPO=${SRIOV_NETWORK_DEVICE_PLUGIN_REPO:-https://github.com/intel/sriov-network-device-plugin}
export SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH=${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH:-master}
export SRIOV_NETWORK_DEVICE_PLUGIN_PR=${SRIOV_NETWORK_DEVICE_PLUGIN_PR-''}

export GOPATH=${WORKSPACE}
export PATH=/usr/local/go/bin/:$GOPATH/src/k8s.io/kubernetes/third_party/etcd:$PATH

export CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin/}
export CNI_CONF_DIR=${CNI_CONF_DIR:-/etc/cni/net.d/}
export ALLOW_PRIVILEGED=${ALLOW_PRIVILEGED:-true}
export NET_PLUGIN=${NET_PLUGIN:-cni}

export KUBE_ENABLE_CLUSTER_DNS=${KUBE_ENABLE_CLUSTER_DNS:-false}
export API_HOST=$(hostname).$(hostname -y)
export API_HOST_IP=$(hostname -I | awk '{print $1}')
export KUBECONFIG=${KUBECONFIG:-/var/run/kubernetes/admin.kubeconfig}

# generate random network
N=$((1 + RANDOM % 128))
export NETWORK=${NETWORK:-"192.168.$N"}

#TODO add autodiscovering
export MACVLAN_INTERFACE=${MACVLAN_INTERFACE:-enp5s0f0}
export SRIOV_INTERFACE=${SRIOV_INTERFACE:-auto_detect}
export VFS_NUM=${VFS_NUM:-4}

echo "Working in $WORKSPACE"
mkdir -p $WORKSPACE
mkdir -p $LOGDIR
mkdir -p $ARTIFACTS

cd $WORKSPACE

echo "Get CPU architechture"
export ARCH="amd"
if [[ $(uname -a) == *"ppc"* ]]; then
   export ARCH="ppc"
fi

function configure_multus {
    echo "Configure Multus"
    date
    sleep 30
    sed -i 's/\/etc\/cni\/net.d\/multus.d\/multus.kubeconfig/\/var\/run\/kubernetes\/admin.kubeconfig/g' $WORKSPACE/multus-cni/images/multus-daemonset.yml

    kubectl create -f $WORKSPACE/multus-cni/images/multus-daemonset.yml

    kubectl -n kube-system get ds
    rc=$?
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       echo "Wait until multus is ready"
       ready=$(kubectl -n kube-system get ds |grep kube-multus-ds-${ARCH}|awk '{print $4}')
       rc=$?
       kubectl -n kube-system get ds
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $ready -eq 1 ]; then
           echo "System is ready"
           break
      fi
    done
    if [ $d -gt $stop ]; then
        kubectl -n kube-system get ds
        echo "kube-multus-ds-${ARCH}64 is not ready in $TIMEOUT sec"
        exit 1
    fi

    multus_config=$CNI_CONF_DIR/99-multus.conf
    cat > $multus_config <<EOF
    {
        "cniVersion": "0.3.0",
        "name": "macvlan-network",
        "type": "macvlan",
        "mode": "bridge",
          "ipam": {
                "type": "host-local",
                "subnet": "${NETWORK}.0/24",
                "rangeStart": "${NETWORK}.100",
                "rangeEnd": "${NETWORK}.216",
                "routes": [{"dst": "0.0.0.0/0"}],
                "gateway": "${NETWORK}.1"
            }
        }
EOF
    cp $multus_config $ARTIFACTS
    return $?
}


function download_and_build {
    status=0
    if [ "$RECLONE" != true ] ; then
        return $status
    fi

    [ -d $CNI_CONF_DIR ] && rm -rf $CNI_CONF_DIR && mkdir -p $CNI_CONF_DIR
    [ -d $CNI_BIN_DIR ] && rm -rf $CNI_BIN_DIR && mkdir -p $CNI_BIN_DIR
    [ -d /var/lib/cni/sriov ] && rm -rf /var/lib/cni/sriov/*

    echo "Download $MULTUS_CNI_REPO"
    rm -rf $WORKSPACE/multus-cni
    git clone $MULTUS_CNI_REPO $WORKSPACE/multus-cni
    cd $WORKSPACE/multus-cni
    # Check if part of Pull Request and
    if test ${MULTUS_CNI_PR}; then
        git fetch --tags --progress $MULTUS_CNI_REPO +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${MULTUS_CNI_PR}/head
    elif test $MULTUS_CNI_BRANCH; then
        git checkout $MULTUS_CNI_BRANCH
    fi
    git log -p -1 > $ARTIFACTS/multus-cni-git.txt
    cd -

    echo "Download $SRIOV_CNI_REPO"
    rm -rf $WORKSPACE/sriov-cni
    git clone ${SRIOV_CNI_REPO} $WORKSPACE/sriov-cni
    pushd $WORKSPACE/sriov-cni
    if test ${SRIOV_CNI_PR}; then
        git fetch --tags --progress ${SRIOV_CNI_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${SRIOV_CNI_PR}/head
    elif test ${SRIOV_CNI_BRANCH}; then
        git checkout ${SRIOV_CNI_BRANCH}
    fi
    git log -p -1 > $ARTIFACTS/sriov-cni-git.txt
    make build
    let status=status+$?
    make image
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build ${SRIOV_CNI_REPO} ${SRIOV_CNI_BRANCH}"
        return $status
    fi
    \cp build/* $CNI_BIN_DIR/
    popd

    echo "Download $PLUGINS_REPO"
    rm -rf $WORKSPACE/plugins
    git clone $PLUGINS_REPO $WORKSPACE/plugins
    pushd $WORKSPACE/plugins
    if test ${PLUGINS_PR}; then
        git fetch --tags --progress ${PLUGINS_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${PLUGINS_PR}/head
    elif test $PLUGINS_BRANCH; then
        git checkout $PLUGINS_BRANCH
    fi
    git log -p -1 > $ARTIFACTS/plugins-git.txt
    bash ./build_linux.sh
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build $PLUGINS_REPO $PLUGINS_BRANCH"
        return $status
    fi

    \cp bin/* $CNI_BIN_DIR/
    popd

    echo "Download ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO}"
    rm -rf $WORKSPACE/sriov-network-device-plugin
    git clone ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} $WORKSPACE/sriov-network-device-plugin
    pushd $WORKSPACE/sriov-network-device-plugin
    if test ${SRIOV_NETWORK_DEVICE_PLUGIN_PR}; then
        git fetch --tags --progress ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${SRIOV_NETWORK_DEVICE_PLUGIN_PR}/head
    elif test ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}; then
        git checkout ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}
    fi
    git log -p -1 > $ARTIFACTS/sriov-network-device-plugin-git.txt
    make build
    let status=status+$?
    make image
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH} ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}"
        return $status
    fi

    \cp build/* $CNI_BIN_DIR/
    popd
    mkdir -p /etc/pcidp/
    cat > /etc/pcidp/config.json <<EOF
{
    "resourceList": [{
        "resourceName": "sriov",
        "selectors": {
                "vendors": ["15b3"],
                "devices": ["1018"],
                "drivers": ["mlx5_core"]
            }
    }
    ]
}
EOF
    cp $WORKSPACE/sriov-network-device-plugin/deployments/configMap.yaml $ARTIFACTS/
    sed -i 's/mlnx_sriov_rdma/sriov/g' $ARTIFACTS/configMap.yaml
    sed -i 's/mlx5_ib/mlx5_core/g' $ARTIFACTS/configMap.yaml

    echo "Download and install kubectl"
    rm -f ./kubectl /usr/local/bin/kubectl
    if [ ${KUBERNETES_VERSION} == 'latest_stable' ]; then
        export KUBERNETES_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}64/kubectl
        chmod +x ./kubectl
        mv ./kubectl /usr/local/bin/kubectl
        kubectl version
    elif [ ${KUBERNETES_VERSION} == 'master' ]; then
        git clone -b ${KUBERNETES_BRANCH} --single-branch --depth=1  https://github.com/kubernetes/kubernetes
        cd kubernetes/
        git show --summary
        make
        mv ./_output/local/go/bin/kubectl /usr/local/bin/kubectl
    else
        curl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}64/kubectl
        mv ./kubectl /usr/local/bin/kubectl
    fi
    chmod +x /usr/local/bin/kubectl
    kubectl version

    echo "Download K8S"
    rm -rf $GOPATH/src/k8s.io/kubernetes
    go get -d k8s.io/kubernetes
    cd $GOPATH/src/k8s.io/kubernetes
    #git checkout $KUBERNETES_BRANCH
    git log -p -1 > $ARTIFACTS/kubernetes.txt
    make
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build K8S $KUBERNETES_BRANCH"
        return $status
    fi

    go get -u github.com/tools/godep
    go get -u github.com/cloudflare/cfssl/cmd/...

    cp /etc/pcidp/config.json $ARTIFACTS
    return 0
}


function create_vfs {
    if [ $SRIOV_INTERFACE == 'auto_detect' ]; then
        export SRIOV_INTERFACE=$(ls -l /sys/class/infiniband/ | grep $(lspci |grep Mellanox |head -n1|awk '{print $1}') | awk '{print $9}')
    fi
    echo 0 > /sys/class/infiniband/$SRIOV_INTERFACE/device/sriov_numvfs
    echo $VFS_NUM > /sys/class/infiniband/$SRIOV_INTERFACE/device/sriov_numvfs
}


function run_k8s {
    $GOPATH/src/k8s.io/kubernetes/hack/install-etcd.sh
    screen -S multus_kube -d -m bash -x $GOPATH/src/k8s.io/kubernetes/hack/local-up-cluster.sh
    kubectl get pods
    rc=$?
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       echo "Wait until K8S is up"
       kubectl get pods
       rc=$?
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $rc -eq 0 ]; then
           echo "K8S is up and running"
           return 0
      fi
    done
    echo "K8S failed to run in $TIMEOUT sec"
    exit 1
}


#TODO add docker image mellanox/mlnx_ofed_linux-4.4-1.0.0.0-centos7.4 presence

create_vfs
download_and_build
if [ $? -ne 0 ]; then
    echo "Failed to download and build components"
    exit 1
fi

run_k8s
if [ $? -ne 0 ]; then
    echo "Failed to run K8S"
    exit 1
fi


configure_multus
if [ $? -ne 0 ]; then
    echo "Failed to configure Multus"
    exit 1
fi





wget https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/master/images/k8s-rdma-shared-dev-plugin-config-map.yaml -O $ARTIFACTS/k8s-rdma-shared-dev-plugin-config-map.yaml
kubectl create -f $ARTIFACTS/k8s-rdma-shared-dev-plugin-config-map.yaml
wget https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/master/images/k8s-rdma-shared-dev-plugin-ds.yaml -O $ARTIFACTS/k8s-rdma-shared-dev-plugin-ds.yaml
kubectl create -f $ARTIFACTS/k8s-rdma-shared-dev-plugin-ds.yaml
wget https://raw.githubusercontent.com/intel/multus-cni/master/images/multus-daemonset.yml -O $ARTIFACTS/multus-daemonset.yml
kubectl create -f $ARTIFACTS/multus-daemonset.yml
wget https://raw.githubusercontent.com/Mellanox/ipoib-cni/master/images/ipoib-cni-daemonset.yaml -O $ARTIFACTS/ipoib-cni-daemonset.yaml
kubectl create -f $ARTIFACTS/ipoib-cni-daemonset.yaml
cat  > $ARTIFACTS/pod.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ipoib-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: rdma/hca_shared_devices_a
spec:
  config: '{
  "cniVersion": "0.3.1",
  "type": "ipoib",
  "name": "mynet",
  "master": "ib0",
  "ipam": {
    "type": "host-local",
    "subnet": "192.168.3.0/24",
    "routes": [{
      "dst": "0.0.0.0/0"
    }],
      "gateway": "192.168.3.1"
  }
}'
EOF
kubectl create -f $ARTIFACTS/pod.yaml
wget https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/master/example/test-hca-pod.yaml -O $ARTIFACTS/test-hca-pod.yaml
kubectl create -f $ARTIFACTS/test-hca-pod.yaml

echo "All code in $WORKSPACE"
echo "All logs $LOGDIR"
echo "All confs $ARTIFACTS"

echo "Setup is up and running. Run following to start tests:"
echo "# WORKSPACE=$WORKSPACE NETWORK=$NETWORK ./ib_cni_test.sh"

exit $status
