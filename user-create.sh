#!/bin/bash

set -e  # Exit on error
cwd=$(pwd)

# Ask for Namespace
echo "Please enter the Kubernetes namespace to create/use:"
read namespace

# Check and create namespace if it doesn't exist
if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    echo "Namespace '$namespace' already exists."
else
    kubectl create namespace "$namespace"
    echo "Namespace '$namespace' created."
fi

# Ask for username
echo "Please enter the Linux/Kubernetes username:"
read username

# Check if user already exists
if id "$username" &>/dev/null; then
    echo "User '$username' already exists on the system."
else
    sudo useradd -m "$username"
    echo "Enter password for $username:"
    read -s password
    echo "$username:$password" | sudo chpasswd
    echo "User '$username' created and password set."
fi

echo "------------------------------ Generating Certificates ------------------------------"

# Generate private key and CSR
openssl genrsa -out "$username.key" 2048
openssl req -new -key "$username.key" -out "$username.csr" -subj "/CN=$username/O=$namespace"

# Copy CA files temporarily
cp /etc/kubernetes/pki/ca.crt "$cwd"
cp /etc/kubernetes/pki/ca.key "$cwd"

# Sign the certificate
openssl x509 -req -in "$username.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "$username.crt" -days 365

echo "------------------------------ Creating kubeconfig File ------------------------------"

# Get current cluster name
clustername=$(kubectl config view -o jsonpath='{.clusters[0].name}')

# Get control plane IP dynamically
server_ip=$(hostname -I | awk '{print $1}')

# Create kubeconfig
kubeconfig_file="$cwd/kubeconfig"
kubectl config --kubeconfig="$kubeconfig_file" set-cluster "$clustername" \
  --server="https://$server_ip:6443" \
  --certificate-authority="$cwd/ca.crt" \
  --embed-certs=true

kubectl config --kubeconfig="$kubeconfig_file" set-credentials "$username" \
  --client-certificate="$cwd/$username.crt" \
  --client-key="$cwd/$username.key" \
  --embed-certs=true

kubectl config --kubeconfig="$kubeconfig_file" set-context "$username-context" \
  --cluster="$clustername" \
  --namespace="$namespace" \
  --user="$username"

kubectl config --kubeconfig="$kubeconfig_file" use-context "$username-context"

echo "------------------------------ Creating User .kube Directory ------------------------------"

user_kube_dir="/home/$username/.kube"
mkdir -p "$user_kube_dir"
cp "$kubeconfig_file" "$user_kube_dir/config"
chown -R "$username:$username" "$user_kube_dir"

echo "------------------------------ Creating RBAC RoleBinding ------------------------------"

# Give read-only access in the namespace (optional - can be customized)
kubectl create rolebinding "$username-view-binding" \
  --clusterrole=view \
  --user="$username" \
  --namespace="$namespace" || echo "RoleBinding already exists."

echo "------------------------------ Cleaning Up ------------------------------"

rm -f "$cwd/ca.crt" "$cwd/ca.key" "$cwd/$username.csr" "$cwd/ca.srl"

echo "✅ Done. User '$username' can now use kubectl with their own kubeconfig at ~/.kube/config"
