# cluster/network — сетевые границы

Применяется Application `network` (gitops/platform/01-network.yaml). Владеет платформа: проекту `shop` NetworkPolicy
запрещены (namespaceResourceBlacklist), чтобы приложение не могло само себе открыть Vault или интернет.

Два уровня:
- `global/` — Calico `GlobalNetworkPolicy` (кластерные, не привязаны к namespace): default-deny для всех
  прикладных namespace, разрешение DNS и доступа к apiserver. Порядок: allow (order 100-110) -> k8s
  NetworkPolicy (Calico ставит им order 1000) -> default-deny (order 10000). Побеждает первое совпавшее правило.
- `<namespace>/` — стандартные `networking.k8s.io/v1 NetworkPolicy`, переносимы на любой CNI: что именно
  разрешено в каждом namespace. Всё, что не перечислено, режет default-deny.

Системные namespace (kube-system, calico-system, calico-apiserver, tigera-operator, local-path-storage)
исключены из ВСЕХ глобальных политик: CoreDNS, kube-proxy, metrics-server, сам Calico. Не только из deny —
в Calico под, к которому применена хоть одна политика в направлении Egress, теряет весь egress, кроме
явно разрешённого; allow-dns на all() оставила бы metrics-server без apiserver.

Проверка: UI Whisker http://whisker.shop.localtest.me (flow-логи allow/deny с именем политики), либо
`kubectl -n shop exec deploy/orders -- python -c "import socket;socket.create_connection(('vault.vault',8200),3)"` -> timeout.
