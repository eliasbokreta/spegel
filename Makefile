TAG = $$(git rev-parse --short HEAD)
IMG ?= ghcr.io/xenitab/spegel:$(TAG)

all: fmt vet lint

lint:
	golangci-lint run ./...

fmt:
	go fmt ./...

vet:
	go vet ./...

test: fmt vet
	go test --cover ./...

docker-build:
	docker build -t ${IMG} .

.PHONY: e2e
.ONESHELL:
e2e: docker-build
	set -ex

	# Create Kind cluster
	TMP_DIR=$$(mktemp -d)
	export KIND_KUBECONFIG=$$TMP_DIR/kind.kubeconfig
	echo $$KIND_KUBECONFIG
	kind create cluster --kubeconfig $$KIND_KUBECONFIG --config ./e2e/kind-config.yaml

	# Pull and load images onto tainted node which will be the local cache.
	docker exec kind-worker ctr -n k8s.io image pull docker.io/library/nginx:1.23.0
	docker exec kind-worker ctr -n k8s.io image pull docker.io/library/nginx@sha256:b3a676a9145dc005062d5e79b92d90574fb3bf2396f4913dc1732f9065f55c4b
	docker exec kind-worker ctr -n k8s.io image pull docker.io/library/nginx:1.21.0@sha256:2f1cd90e00fe2c991e18272bb35d6a8258eeb27785d121aa4cc1ae4235167cfd

	# Deploy Redis and Spegel
	kubectl --kubeconfig $$KIND_KUBECONFIG create namespace spegel
	helm repo add bitnami https://charts.bitnami.com/bitnami
	helm --kubeconfig $$KIND_KUBECONFIG upgrade --install --namespace spegel redis bitnami/redis --set "auth.enabled=false"
	kind load docker-image ${IMG}
	helm --kubeconfig $$KIND_KUBECONFIG upgrade --install --namespace="spegel" spegel ./charts/spegel --set "image.pullPolicy=Never" --set "image.tag=${TAG}" --set "spegel.redisAddr=redis-master.spegel.svc.cluster.local:6379"

	# Deploy test Nginx pods and expect pull to work
	kubectl --kubeconfig $$KIND_KUBECONFIG apply -f ./e2e/test-nginx.yaml
	kubectl --kubeconfig $$KIND_KUBECONFIG --namespace nginx wait deployment/nginx-tag --for condition=available
	kubectl --kubeconfig $$KIND_KUBECONFIG --namespace nginx wait deployment/nginx-digest --for condition=available
	kubectl --kubeconfig $$KIND_KUBECONFIG --namespace nginx wait deployment/nginx-tag-and-digest --for condition=available

	# Delete cluster
	#kind delete cluster