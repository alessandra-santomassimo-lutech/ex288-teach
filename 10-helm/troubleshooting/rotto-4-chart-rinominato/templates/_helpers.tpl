{{/*
Funzioni di supporto (named template) del chart hello-chart.
I file che iniziano con "_" non producono oggetti: contengono solo "define".
*/}}

{{/*
Nome base degli oggetti: il nome della release (o fullnameOverride),
troncato a 50 caratteri per lasciare spazio ai suffissi -app, -db, -config.
*/}}
{{- define "hello-chart.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{/*
Label di selezione: NON devono mai cambiare dopo la prima installazione,
perché spec.selector di un Deployment è immutabile.
*/}}
{{- define "hello-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Label comuni da mettere in metadata.labels di ogni oggetto.
*/}}
{{- define "hello-chart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "hello-chart.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Immagine dell'applicazione. Se app.image.repository è vuoto usa l'image stream
hello-node del registry interno, nel namespace in cui viene installata la release.
*/}}
{{- define "hello-chart.appImage" -}}
{{- $repo := .Values.app.image.repository | default (printf "image-registry.openshift-image-registry.svc:5000/%s/hello-node" .Release.Namespace) -}}
{{- printf "%s:%s" $repo .Values.app.image.tag -}}
{{- end -}}
