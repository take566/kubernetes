echo %date%
echo %time%

SET yyyy=%date:~0,4%
SET mm=%date:~5,2%
SET dd=%date:~8,2%

SET time2=%time: =0%

SET hh=%time2:~0,2%
SET mn=%time2:~3,2%
SET ss=%time2:~6,2%

SET filename=%yyyy%-%mm%%dd%-%hh%%mn%%ss%
SET LOG=C:\work\log\k8_rancher_%filename%.txt
cd C:\work\kubernetes\rancher

# Install the CustomResourceDefinition resources separately
kubectl apply --validate=false -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.12/deploy/manifests/00-crds.yaml  >> %LOG%

# Create the namespace for cert-manager  
kubectl create namespace cert-manager  >> %LOG%

# Label the cert-manager namespace to disable resource validation
kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true  >> %LOG%

# Add the Jetstack Helm repository  
helm repo add jetstack https://charts.jetstack.io  >> %LOG%
# Update your local Helm chart repository cache  
helm repo update# Install the cert-manager Helm chart  >> %LOG%
# Note with helm 3 Usage:  helm install [NAME] [CHART] [flags]  
helm install cert-manager jetstack/cert-manager --namespace cert-manager --version v0.12.0  >> %LOG%
kubectl.exe -n cert-manager get pods,services,ingresses  >> %LOG%

helm repo add rancher-stable https://releases.rancher.com/server-charts/stable  >> %LOG%
helm repo update  >> %LOG%
kubectl create namespace cattle-system  >> %LOG%
helm install rancher rancher-stable/rancher --namespace cattle-system --set hostname=rancher.localdev  >> %LOG%