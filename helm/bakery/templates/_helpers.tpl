{{/*
Namespace every resource is rendered into. Always driven by values so
`helm upgrade --install -n bakery-<env>` and this field agree.
*/}}
{{- define "bakery.namespace" -}}
{{ .Values.global.namespace }}
{{- end -}}

{{/*
Common labels applied to every resource.
*/}}
{{- define "bakery.labels" -}}
app.kubernetes.io/part-of: crumb-and-ember
app.kubernetes.io/managed-by: {{ .Release.Service }}
bakery.io/environment: {{ .Values.environment }}
{{- end -}}

{{/*
Full container image reference for a service entry: registry/name:tag,
falling back to global.imageTag when the service doesn't pin its own.
*/}}
{{- define "bakery.image" -}}
{{- $svc := .svc -}}
{{- $root := .root -}}
{{- $tag := $svc.imageTag | default $root.Values.global.imageTag -}}
{{ $root.Values.global.imageRegistry }}/{{ $svc.name }}:{{ $tag }}
{{- end -}}

{{/*
Renders the `env:` list for a service from its declarative `env` entries.
Each entry is either { name, value } or { name, secretRef: { name, key, optional } }.
*/}}
{{- define "bakery.env" -}}
- name: SERVICE_NAME
  value: {{ .svc.name | quote }}
- name: PORT
  value: {{ .svc.port | quote }}
- name: LOG_LEVEL
  value: {{ .root.Values.global.logLevel | default "info" | quote }}
{{- range .svc.env }}
- name: {{ .name }}
  {{- if .value }}
  value: {{ .value | quote }}
  {{- else if .secretRef }}
  valueFrom:
    secretKeyRef:
      name: {{ .secretRef.name }}
      key: {{ .secretRef.key }}
      {{- if .secretRef.optional }}
      optional: true
      {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Resolved replica count for an internal service: replicaOverrides[name],
falling back to replicaCount.default.
*/}}
{{- define "bakery.replicas" -}}
{{- $override := index .root.Values.replicaOverrides .svc.name -}}
{{- if $override -}}{{ $override }}{{- else -}}{{ .root.Values.replicaCount.default }}{{- end -}}
{{- end -}}

{{/*
Resolved replica count for an edge service (api-gateway/frontend):
edgeReplicaOverrides[name], falling back to edgeReplicaCount.default.
*/}}
{{- define "bakery.edgeReplicas" -}}
{{- $override := index .root.Values.edgeReplicaOverrides .svc.name -}}
{{- if $override -}}{{ $override }}{{- else -}}{{ .root.Values.edgeReplicaCount.default }}{{- end -}}
{{- end -}}

{{/*
Resource requests/limits for an internal service: resourceOverrides[name],
falling back to resources.default.
*/}}
{{- define "bakery.resources" -}}
{{- $override := index .root.Values.resourceOverrides .svc.name -}}
{{- $r := $override | default .root.Values.resources.default -}}
requests:
  cpu: {{ $r.requests.cpu }}
  memory: {{ $r.requests.memory }}
limits:
  cpu: {{ $r.limits.cpu }}
  memory: {{ $r.limits.memory }}
{{- end -}}

{{/*
Renders one Deployment for an edge service's stable or canary track.
Expects: svc, root, track ("stable"|"canary"), replicas, imageTag.
*/}}
{{- define "bakery.edgeDeployment" -}}
{{- $svc := .svc -}}
{{- $root := .root -}}
{{- $track := .track -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $svc.name }}-{{ $track }}
  namespace: {{ include "bakery.namespace" $root }}
  labels:
    app: {{ $svc.name }}
    track: {{ $track }}
    {{- include "bakery.labels" $root | nindent 4 }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      app: {{ $svc.name }}
      track: {{ $track }}
  template:
    metadata:
      labels:
        app: {{ $svc.name }}
        track: {{ $track }}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: {{ $svc.runAsUser }}
        runAsGroup: {{ $svc.runAsUser }}
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {{ $svc.name }}
          image: {{ $root.Values.global.imageRegistry }}/{{ $svc.name }}:{{ .imageTag }}
          imagePullPolicy: {{ $root.Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ $svc.port }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          {{- if $svc.volumeMounts }}
          volumeMounts:
            {{- toYaml $svc.volumeMounts | nindent 12 }}
          {{- end }}
          env:
            {{- include "bakery.env" (dict "svc" $svc "root" $root) | nindent 12 }}
          readinessProbe:
            httpGet:
              path: {{ $svc.healthPath.ready }}
              port: {{ $svc.port }}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: {{ $svc.healthPath.live }}
              port: {{ $svc.port }}
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            {{- include "bakery.edgeResources" (dict "root" $root) | nindent 12 }}
      {{- if $svc.volumes }}
      volumes:
        {{- toYaml $svc.volumes | nindent 8 }}
      {{- end }}
{{- end -}}

{{/*
Resource requests/limits for an edge service: resources.edge.
*/}}
{{- define "bakery.edgeResources" -}}
{{- $r := .root.Values.resources.edge -}}
requests:
  cpu: {{ $r.requests.cpu }}
  memory: {{ $r.requests.memory }}
limits:
  cpu: {{ $r.limits.cpu }}
  memory: {{ $r.limits.memory }}
{{- end -}}
