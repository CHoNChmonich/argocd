{{/*
Именованные шаблоны (helpers). Вызываются через include "shop.<name>" <context>.
*/}}

{{- define "shop.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/* Общие метки чарта (на всех объектах) */}}
{{- define "shop.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/part-of: {{ include "shop.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
Метки конкретного сервиса. Контекст: dict "root" $ "name" <service>.
Селекторы (Deployment.spec.selector, Service.spec.selector, PDB, HPA) должны быть НЕИЗМЕНЯЕМЫМИ —
поэтому отдельный helper только с app.kubernetes.io/name, без версии чарта.
*/}}
{{- define "shop.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/* Полный набор значений сервиса = serviceDefaults, поверх — services.<name> (глубокое слияние) */}}
{{- define "shop.serviceValues" -}}
{{- $defaults := deepCopy .root.Values.serviceDefaults -}}
{{- $overrides := index .root.Values.services .name | default dict -}}
{{- mustMergeOverwrite $defaults $overrides | toYaml -}}
{{- end -}}

{{/* Полное имя образа сервиса */}}
{{- define "shop.image" -}}
{{- $tag := .root.Values.image.tag | default .root.Chart.AppVersion -}}
{{- printf "%s/%s/%s:%s" .root.Values.image.registry .root.Values.image.repository .name $tag -}}
{{- end -}}
