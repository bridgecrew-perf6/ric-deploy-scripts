#!/bin/bash

. /ric-vars

KUBE_CONFIG=/ric-install/kubernetes/${KUBERNETES_VERSION}

echo configure docker
cp /ric-install/config/docker-daemon.json /etc/docker/docker-daemon.json
systemctl restart docker

echo start kubernetes install
kubeadm init --kubernetes-version=${KUBERNETES_VERSION} \
             --pod-network-cidr=${KUBERNETES_CIDR}      \
             --config ${KUBE_CONFIG}/config.yml

# While kubernetes start, let's do something else
echo download and install helm
pushd /tmp
wget https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz
tar xf helm-v${HELM_VERSION}-linux-amd64.tar.gz
cp linux-amd64/helm /usr/local/bin/helm # XXX should use /sbin/install, is it available?
popd

echo enable docker and kubelet on boot
systemctl enable docker
systemctl enable kubelet
touch /etc/cloud/cloud-init.disabled

echo clone O-RAN ric
git clone http://gerrit.o-ran-sc.org/r/it/dep /ric 
pushd /ric
git checkout -b ${RIC_RELEASE} origin/${RIC_RELEASE}
git submodule update --init --recursive --remote
popd

echo continue ric install
mkdir ${HOME}/.kube
ln -s /etc/kubernetes/admin.conf ${HOME}/.kube/config

echo waiting to install flannel
while [[ $(kubectl get pods -n kube-system | grep Running | wc -l) -lt 5 ]] ; do sleep 5 ; done

echo install flannel
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

echo wait for all pods to be running
while [[ $(kubectl get pods -n kube-system | grep Running | wc -l) -lt 8 ]] ; do sleep 5 ; done

# kubectl taint nodes --all node-role.kubernetes.io/master- ??

echo create rbac
kubectl create -f i${KUBE_CONFIG}/rbac.yml

echo initialize helm
helm init --service-account tiller                                                                    \
          --override spec.selector.matchLabels.'name'='tiller',spec.selector.matchLabels.'app'='helm' \
          --output yaml > /tmp/helm-init.yaml

sed 's@apiVersion: extensions/v1beta1@apiVersion: apps/v1@' /tmp/helm-init.yaml > /tmp/helm-init-patched.yaml
kubectl apply -f /tmp/helm-init-patched.yaml

helm init -c

echo waiting for helm to start
while ! helm version ; do sleep 5 ; done

echo disable cloud-init and end
touch /etc/cloud/cloud-init.disabled
